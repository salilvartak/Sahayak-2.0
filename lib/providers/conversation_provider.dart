import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/conversation_turn.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../utils/image_utils.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/language.dart';
import 'settings_provider.dart';
import '../localization/app_localizations.dart';
import '../services/backend_service.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/vad_controller.dart';
import '../services/vad_pipeline.dart';
import '../services/azure_streaming_client.dart';

// PART 5 — Full state machine
enum AppVoiceState {
  idle,
  listening,   // Always-on mic active, waiting for speech
  capturing,   // Speech detected, streaming to STT
  transcribing, // 750ms silence, awaiting final STT result
  thinking,    // STT done, LLM processing
  streaming,   // TTS actively speaking response sentence-by-sentence
  speaking,    // Alias kept for legacy widget compatibility
  error,
  interrupted, // User spoke while AI was talking (brief flash)
}

class ConversationState {
  final AppVoiceState status;
  final String lastResponse;
  final List<ConversationTurn> history;
  final bool isFlashOn;
  final Map<String, int> latencyMs; // Observability

  const ConversationState({
    this.status = AppVoiceState.idle,
    this.lastResponse = '',
    this.history = const [],
    this.isFlashOn = false,
    this.latencyMs = const {},
  });

  ConversationState copyWith({
    AppVoiceState? status,
    String? lastResponse,
    List<ConversationTurn>? history,
    bool? isFlashOn,
    Map<String, int>? latencyMs,
  }) {
    return ConversationState(
      status: status ?? this.status,
      lastResponse: lastResponse ?? this.lastResponse,
      history: history ?? this.history,
      isFlashOn: isFlashOn ?? this.isFlashOn,
      latencyMs: latencyMs ?? this.latencyMs,
    );
  }
}

final conversationProvider =
    StateNotifierProvider<ConversationNotifier, ConversationState>((ref) {
  return ConversationNotifier(ref);
});

class ConversationNotifier extends StateNotifier<ConversationState> {
  final Ref _ref;
  final CameraService _cameraService = CameraService();
  final AudioRecorder _recorder = AudioRecorder();
  final TTSService _ttsService = TTSService();
  final BackendService _backendService = BackendService();
  final VadController _vadController = VadController();
  late final VadPipeline _vadPipeline;

  Language _detectedLanguage = Language.english;

  StreamSubscription<Uint8List>? _audioStreamSub;
  AzureStreamingClient? _streamingClient;

  // PART 5 — Interrupt + context tracking
  int _requestGeneration = 0; // Increment to invalidate stale LLM responses
  String _partialResponse = ''; // What AI had said before being interrupted
  final String _lastIntent = '';
  bool _wasInterruption = false;
  String _currentSessionId = 'default';

  // PART 10 — Latency stopwatches
  final Stopwatch _captureWatch = Stopwatch();
  final Stopwatch _llmWatch = Stopwatch();
  final Stopwatch _ttsWatch = Stopwatch();

  ConversationNotifier(this._ref) : super(const ConversationState()) {
    _vadPipeline = VadPipeline(
      vadController: _vadController,
      onStateChanged: _onVadStateChanged,
      onAudioCaptured: _onVadAudioCaptured,
    );

    // Wire up TTS completion callbacks
    _ttsService.onSentenceStarted = _onTtsSentenceStarted;
    _ttsService.onAllCompleted = _onTtsAllCompleted;

    initialize();
  }

  // ---------------------------------------------------------------------------
  // PART 10 — Observability helpers
  // ---------------------------------------------------------------------------

  void _logTransition(AppVoiceState from, AppVoiceState to) {
    debugPrint('[STATE] ${from.name} → ${to.name}');
  }

  void _setState(
    AppVoiceState newStatus, {
    String? lastResponse,
    List<ConversationTurn>? history,
    bool? isFlashOn,
    Map<String, int>? latencyMs,
  }) {
    _logTransition(state.status, newStatus);
    state = state.copyWith(
      status: newStatus,
      lastResponse: lastResponse,
      history: history,
      isFlashOn: isFlashOn,
      latencyMs: latencyMs,
    );
  }

  // ---------------------------------------------------------------------------
  // TTS Callbacks
  // ---------------------------------------------------------------------------

  void _onTtsSentenceStarted() {
    if (state.status != AppVoiceState.streaming) {
      _setState(AppVoiceState.streaming);
    }
  }

  void _onTtsAllCompleted() {
    _ttsWatch.stop();
    debugPrint('[Latency] TTS total: ${_ttsWatch.elapsedMilliseconds}ms');
    _vadController.onTtsStopped();
    if (mounted) {
      _setState(AppVoiceState.listening);
      _vadPipeline.reset();
    }
  }

  // ---------------------------------------------------------------------------
  // PART 5 — VAD → State Machine
  // ---------------------------------------------------------------------------

  void _onVadStateChanged(bool isSpeaking) {
    if (isSpeaking) {
      final current = state.status;

      // Interrupt only while TTS is actively speaking
      if (current == AppVoiceState.streaming ||
          current == AppVoiceState.speaking) {
        _handleInterrupt();
        return;
      }

      // Only begin capture from listening state
      if (current != AppVoiceState.listening) return;

      _setState(AppVoiceState.capturing);
      _captureWatch.reset();
      _captureWatch.start();

      // Start real-time STT WebSocket immediately
      _streamingClient?.stopStream();
      _streamingClient = AzureStreamingClient(
        onPartialResult: (text) => debugPrint('[STT] Partial: $text'),
        onFinalResult: _processFinalSttText,
        onError: (e) {
          debugPrint('[STT] WS error: $e');
          // Retry WebSocket on transient error
          if (state.status == AppVoiceState.capturing && mounted) {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (state.status == AppVoiceState.capturing && mounted) {
                debugPrint('[STT] Retrying WebSocket');
                _streamingClient = AzureStreamingClient(
                  onPartialResult: (t) => debugPrint('[STT] Partial: $t'),
                  onFinalResult: _processFinalSttText,
                  onError: (e2) => debugPrint('[STT] Retry failed: $e2'),
                )..startStream(language: 'en-US');
              }
            });
          }
        },
      )..startStream(language: 'en-US');
    } else {
      // 750ms silence → end capture only if we were capturing
      if (state.status != AppVoiceState.capturing) return;

      _captureWatch.stop();
      debugPrint('[Latency] Capture: ${_captureWatch.elapsedMilliseconds}ms');
      _setState(AppVoiceState.transcribing);
      _streamingClient?.stopStream(); // Closing forces Azure to emit final phrase
    }
  }

  // PART 5 — Interrupt logic
  void _handleInterrupt() {
    debugPrint('[INTERRUPT] User interrupted at state=${state.status.name}');

    _partialResponse = state.lastResponse; // Save what AI had spoken
    _wasInterruption = true;
    ++_requestGeneration; // Invalidate any in-flight LLM request

    _ttsService.stop();
    _vadController.onTtsStopped();
    _ttsWatch.stop();

    // Start new STT stream immediately so we don't lose the interrupt utterance
    _streamingClient?.stopStream();
    _streamingClient = AzureStreamingClient(
      onPartialResult: (t) => debugPrint('[STT] Interrupt partial: $t'),
      onFinalResult: _processFinalSttText,
      onError: (e) => debugPrint('[STT] Interrupt WS error: $e'),
    )..startStream(language: 'en-US');

    // Flash the interrupted state briefly, then move to capturing
    _setState(AppVoiceState.interrupted);
    _captureWatch.reset();
    _captureWatch.start();

    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && state.status == AppVoiceState.interrupted) {
        _setState(AppVoiceState.capturing);
      }
    });
  }

  void _onVadAudioCaptured(Uint8List frame) {
    if (state.status == AppVoiceState.capturing ||
        state.status == AppVoiceState.interrupted) {
      _streamingClient?.sendAudioChunk(frame);
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  CameraService get cameraService => _cameraService;

  Future<void> initialize() async {
    try {
      final deviceId = await _getDeviceId();
      _currentSessionId = '${deviceId}_${DateTime.now().millisecondsSinceEpoch}';
      debugPrint('[Init] device=$deviceId session=$_currentSessionId');

      final items = await _backendService.getHistory(deviceId);
      final history = items.map((item) => ConversationTurn(
            query: item['query'] ?? '',
            response: item['response'] ?? '',
            timestamp:
                DateTime.tryParse(item['timestamp'] ?? '') ?? DateTime.now(),
            imagePath: item['image_url'],
          )).toList();

      state = state.copyWith(history: history);

      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      if (!cameraStatus.isGranted || !micStatus.isGranted) {
        _setState(AppVoiceState.error);
        const lang = Language.english;
        await _ttsService.speak(
            AppLocalizations(lang).translate('permission_error'), lang);
        return;
      }

      try {
        await _cameraService.initialize();
      } catch (e) {
        debugPrint('[Init] Camera failed: $e');
        _setState(AppVoiceState.error);
        const lang = Language.english;
        await _ttsService.speak(
            AppLocalizations(lang).translate('camera_error'), lang);
        return;
      }

      final settings = _ref.read(settingsProvider);
      if (settings.tutorialCompleted) {
        const lang = Language.english;
        await _ttsService.speak(
            AppLocalizations(lang).translate('welcome_message'), lang);
      }

      // PART 5 — Auto-start always-on listening (no PTT needed)
      await startListening();
    } catch (e) {
      debugPrint('[Init] Error: $e');
      _setState(AppVoiceState.error);
    }
  }

  Future<void> startListening() async {
    try {
      if (!await _recorder.hasPermission()) return;
      if (state.status == AppVoiceState.listening) return; // Already active

      _setState(AppVoiceState.listening);
      _audioStreamSub?.cancel();

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          echoCancel: true,   // Layer 1: hardware AEC
          noiseSuppress: true,
          autoGain: true,
        ),
      );

      _audioStreamSub = stream.listen((data) => _vadPipeline.feedAudio(data));
      debugPrint('[Mic] Always-on listening started');
    } catch (e) {
      debugPrint('[Mic] Start error: $e');
      _setState(AppVoiceState.error);
    }
  }

  Future<void> processTextQuery(String query, Language language) async {
    _setState(AppVoiceState.thinking);
    final myGeneration = ++_requestGeneration;

    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) throw Exception('Camera capture failed');
      final compressed = await ImageUtils.compressImage(xFile.path);
      final deviceId = await _getDeviceId();

      _llmWatch.reset();
      _llmWatch.start();

      final resp = await _backendService.getResponse(
        deviceId: deviceId,
        query: query,
        imageFile: File(compressed.path),
        language: language,
        sessionId: _currentSessionId,
      );

      _llmWatch.stop();
      debugPrint('[Latency] LLM: ${_llmWatch.elapsedMilliseconds}ms');

      if (_requestGeneration != myGeneration) {
        debugPrint('[State] Stale text query response discarded');
        return;
      }

      debugPrint('[Context] interaction_id=${resp.interactionId}');
      final newTurn = ConversationTurn(
        query: query,
        response: resp.response,
        timestamp: DateTime.now(),
        imagePath: null,
      );

      _setState(AppVoiceState.streaming,
          lastResponse: resp.response,
          history: [newTurn, ...state.history]);

      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);
      _vadController.onTtsStarted();
      _ttsWatch.reset();
      _ttsWatch.start();
      await _ttsService.speakStreaming(resp.response, language);
    } catch (e) {
      debugPrint('[Error] processTextQuery: $e');
      _setState(AppVoiceState.error);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) _setState(AppVoiceState.listening);
      });
    }
  }

  // Legacy blocking speak (tutorial, welcome message)
  Future<void> speak(String text, dynamic language) async {
    _vadController.onTtsStarted();
    await _ttsService.speak(text, language);
    _vadController.onTtsStopped();
  }

  Future<void> _processFinalSttText(
      String transcript, String languageCode) async {
    if (transcript.isEmpty || transcript.length < 2) {
      if (mounted) {
        _setState(AppVoiceState.listening);
        _vadPipeline.reset();
      }
      return;
    }

    _setState(AppVoiceState.thinking);
    final myGeneration = ++_requestGeneration;
    debugPrint('[STT] Final: "$transcript" lang=$languageCode');

    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) throw Exception('Camera capture failed');
      final compressed = await ImageUtils.compressImage(xFile.path);

      _detectedLanguage = _mapAzureLanguage(languageCode);
      final deviceId = await _getDeviceId();

      _llmWatch.reset();
      _llmWatch.start();

      // PART 7 — Context-aware payload with interrupt fields
      final resp = await _backendService.getResponse(
        deviceId: deviceId,
        query: transcript,
        imageFile: File(compressed.path),
        language: _detectedLanguage,
        sessionId: _currentSessionId,
        wasInterruption: _wasInterruption,
        partialResponse: _partialResponse,
        previousIntent: _lastIntent,
      );

      _llmWatch.stop();
      debugPrint('[Latency] LLM: ${_llmWatch.elapsedMilliseconds}ms');

      // PART 5 — Discard if a newer request has been issued
      if (_requestGeneration != myGeneration) {
        debugPrint('[State] Stale LLM response discarded');
        return;
      }

      // Reset interrupt context after successful response
      _wasInterruption = false;
      _partialResponse = '';
      debugPrint('[Context] interaction_id=${resp.interactionId}');

      final newTurn = ConversationTurn(
        query: transcript,
        response: resp.response,
        timestamp: DateTime.now(),
        imagePath: null,
      );

      _setState(
        AppVoiceState.streaming,
        lastResponse: resp.response,
        history: [newTurn, ...state.history],
        latencyMs: {'llm_ms': _llmWatch.elapsedMilliseconds},
      );

      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);
      _vadController.onTtsStarted();
      _ttsWatch.reset();
      _ttsWatch.start();
      await _ttsService.speakStreaming(resp.response, _detectedLanguage);
    } catch (e) {
      debugPrint('[Error] _processFinalSttText: $e');
      if (_requestGeneration == myGeneration && mounted) {
        _setState(AppVoiceState.error);
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted) {
            _setState(AppVoiceState.listening);
            _vadPipeline.reset();
          }
        });
      }
    }
  }

  void stopSpeaking() {
    _ttsService.stop();
    _vadController.onTtsStopped();
    ++_requestGeneration;
    _setState(AppVoiceState.listening);
    _vadPipeline.reset();
  }

  void clearResponse() {
    if (state.status == AppVoiceState.streaming ||
        state.status == AppVoiceState.speaking) {
      _ttsService.stop();
      _vadController.onTtsStopped();
    }
    state = state.copyWith(lastResponse: '', status: AppVoiceState.listening);
  }

  void toggleListening() {
    switch (state.status) {
      case AppVoiceState.streaming:
      case AppVoiceState.speaking:
        stopSpeaking();
        break;
      case AppVoiceState.thinking:
        ++_requestGeneration;
        _setState(AppVoiceState.listening);
        _vadPipeline.reset();
        break;
      case AppVoiceState.listening:
      case AppVoiceState.capturing:
        _setState(AppVoiceState.transcribing);
        _streamingClient?.stopStream();
        break;
      case AppVoiceState.idle:
      case AppVoiceState.error:
      case AppVoiceState.interrupted:
        startListening();
        break;
      case AppVoiceState.transcribing:
        break;
    }
  }

  Future<void> switchCamera() async {
    await _cameraService.switchCamera();
    state = state.copyWith();
  }

  Future<void> toggleFlash() async {
    await _cameraService.toggleFlash();
    state = state.copyWith(isFlashOn: _cameraService.isFlashOn);
  }

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('device_id');
    if (id == null) {
      id = '${DateTime.now().millisecondsSinceEpoch}'
          '-${1000000 + (DateTime.now().microsecond % 9000000)}';
      await prefs.setString('device_id', id);
    }
    return id;
  }

  Language _mapAzureLanguage(String azureCode) {
    final code = azureCode.toLowerCase();
    if (code.contains('hi')) return Language.hindi;
    if (code.contains('mr')) return Language.marathi;
    if (code.contains('te')) return Language.telugu;
    return Language.english;
  }

  @override
  void dispose() {
    _audioStreamSub?.cancel();
    _streamingClient?.stopStream();
    _cameraService.dispose();
    _recorder.dispose();
    _ttsService.stop();
    super.dispose();
  }
}
