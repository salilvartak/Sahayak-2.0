import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/conversation_turn.dart';
import '../models/language.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/backend_service.dart';
import '../services/azure_speech_service.dart';
import '../services/barcode_service.dart';
import '../utils/image_utils.dart';
import 'package:permission_handler/permission_handler.dart';
import 'settings_provider.dart';
import '../localization/app_localizations.dart';

enum AppState { idle, listening, thinking, speaking, error }

class ConversationState {
  final AppState status;
  final String lastResponse;
  final List<ConversationTurn> history;
  final bool isFlashOn;

  const ConversationState({
    this.status = AppState.idle,
    this.lastResponse = '',
    this.history = const [],
    this.isFlashOn = false,
  });

  ConversationState copyWith({
    AppState? status,
    String? lastResponse,
    List<ConversationTurn>? history,
    bool? isFlashOn,
  }) {
    return ConversationState(
      status: status ?? this.status,
      lastResponse: lastResponse ?? this.lastResponse,
      history: history ?? this.history,
      isFlashOn: isFlashOn ?? this.isFlashOn,
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
  final AzureSpeechService _azureSpeechService = AzureSpeechService();
  final TTSService _ttsService = TTSService();
  final BackendService _backendService = BackendService();
  final BarcodeService _barcodeService = BarcodeService();

  String? _recordingPath;
  Language _detectedLanguage = Language.english;
  String _currentSessionId = 'default';

  ConversationNotifier(this._ref) : super(const ConversationState());

  CameraService get cameraService => _cameraService;

  Future<void> initialize() async {
    try {
      final deviceId = await _getDeviceId();
      _currentSessionId = '${deviceId}_${DateTime.now().millisecondsSinceEpoch}';

      try {
        final items = await _backendService.getHistory(deviceId);
        final history = items.map((item) => ConversationTurn(
              query: item['query'] ?? '',
              response: item['response'] ?? '',
              timestamp:
                  DateTime.tryParse(item['timestamp'] ?? '') ?? DateTime.now(),
              imagePath: item['image_url'],
              language: item['language'] as String? ?? 'hi-IN',
            )).toList();
        state = state.copyWith(history: history);
      } catch (e) {
        debugPrint('[Init] History load failed (non-fatal): $e');
      }

      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      if (!cameraStatus.isGranted || !micStatus.isGranted) {
        state = state.copyWith(status: AppState.error);
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(
            localizations.translate('permission_error'), language);
        return;
      }

      try {
        await _cameraService.initialize();
        state = state.copyWith();
      } catch (e) {
        debugPrint('[Init] Camera initialization failed: $e');
        state = state.copyWith(status: AppState.error);
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(
            localizations.translate('camera_error'), language);
        return;
      }

      final settings = _ref.read(settingsProvider);
      if (settings.tutorialCompleted) {
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(
            localizations.translate('welcome_message'), language);
      }

      state = state.copyWith();
    } catch (e) {
      debugPrint('[Init] Error: $e');
      state = state.copyWith(status: AppState.error);
    }
  }

  Future<void> speak(String text, dynamic language) async {
    await _ttsService.speak(text, language);
  }

  Future<void> startListening() async {
    try {
      if (await _recorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        _recordingPath = p.join(directory.path, 'audio_capture.wav');

        state = state.copyWith(status: AppState.listening);

        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: _recordingPath!,
        );
      }
    } catch (e) {
      debugPrint('[Mic] Start error: $e');
      state = state.copyWith(status: AppState.error);
    }
  }

  Future<void> stopListeningAndProcess() async {
    final String? path = await _recorder.stop();
    if (path == null) {
      state = state.copyWith(status: AppState.idle);
      return;
    }
    state = state.copyWith(status: AppState.thinking);

    try {
      // Parallel: capture+compress image AND transcribe audio
      final captureTask = _captureAndCompress();
      final sttTask = _azureSpeechService.recognize(path);
      final captureResult = await captureTask;
      final sttResult = await sttTask;
      final compressedFile = captureResult.file;
      final barcode = captureResult.barcode;

      final transcript =
          sttResult.transcript.isNotEmpty ? sttResult.transcript : 'What is this?';
      _detectedLanguage = Language.fromBcp47(sttResult.language);

      final deviceId = await _getDeviceId();
      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);

      // --- Streaming TTS pipeline ---
      bool speakingStarted = false;
      bool streamingDone = false;
      final fullResponse = StringBuffer();
      final sentenceBuffer = StringBuffer();

      // When TTS queue drains AND stream is done → go idle
      _ttsService.onAllCompleted = () {
        if (streamingDone && mounted) {
          _ttsService.onAllCompleted = null;
          state = state.copyWith(status: AppState.idle);
        }
      };

      void flushSentence(String sentence) {
        if (sentence.isEmpty) return;
        if (!speakingStarted) {
          speakingStarted = true;
          state = state.copyWith(status: AppState.speaking);
        }
        _ttsService.speakStreaming(sentence, _detectedLanguage).ignore();
      }

      // Sentence-boundary regex: split after . ! ? । followed by whitespace
      final sentenceBoundary = RegExp(r'(?<=[.!?।])\s+');

      await for (final token in _backendService.streamResponse(
        deviceId: deviceId,
        query: transcript,
        imageFile: compressedFile,
        barcode: barcode,
        language: _detectedLanguage,
        sessionId: _currentSessionId,
      )) {
        fullResponse.write(token);
        sentenceBuffer.write(token);

        final text = sentenceBuffer.toString();
        final match = sentenceBoundary.firstMatch(text);
        if (match != null) {
          flushSentence(text.substring(0, match.end).trim());
          sentenceBuffer
            ..clear()
            ..write(text.substring(match.end));
        }
      }

      // Flush any remaining text after stream ends
      flushSentence(sentenceBuffer.toString().trim());
      streamingDone = true;

      // Add to history
      final responseText = fullResponse.toString();
      final newTurn = ConversationTurn(
        query: transcript,
        response: responseText,
        timestamp: DateTime.now(),
        imagePath: null,
        language: sttResult.language,
      );
      state = state.copyWith(
        lastResponse: responseText,
        history: [newTurn, ...state.history],
      );

      // If nothing was spoken or TTS already finished, go idle now
      if (!speakingStarted || _ttsService.isIdle) {
        _ttsService.onAllCompleted = null;
        state = state.copyWith(status: AppState.idle);
      }
    } catch (e, stackTrace) {
      debugPrint('[Error] stopListeningAndProcess: $e');
      debugPrint('$stackTrace');
      _ttsService.onAllCompleted = null;
      state = state.copyWith(status: AppState.error);
      const language = Language.english;
      final localizations = AppLocalizations(language);

      String errorKey = 'connection_error';
      if (e.toString().contains('Camera')) {
        errorKey = 'camera_error';
      } else if (e.toString().contains('API Error')) {
        errorKey = 'api_error';
      } else if (e is SocketException) {
        errorKey = 'connection_error';
      }

      await _ttsService.speak(localizations.translate(errorKey), language);

      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) state = state.copyWith(status: AppState.idle);
      });
    }
  }

  /// Capture a camera frame, detect barcode, and compress image in background.
  /// Returns null if the camera is unavailable (non-fatal — backend handles
  /// null image gracefully).
  Future<_CaptureResult> _captureAndCompress() async {
    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) return const _CaptureResult(file: null, barcode: null);
      final barcode = await _barcodeService.scanImagePath(xFile.path);
      final compressed = await ImageUtils.compressImage(xFile.path);
      return _CaptureResult(file: compressed, barcode: barcode);
    } catch (e) {
      debugPrint('[Capture] Failed (non-fatal): $e');
      return const _CaptureResult(file: null, barcode: null);
    }
  }

  Future<void> processTextQuery(String query, Language language) async {
    state = state.copyWith(status: AppState.thinking);

    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) throw Exception('Camera capture failed');

      final barcode = await _barcodeService.scanImagePath(xFile.path);
      final compressedFile = await ImageUtils.compressImage(xFile.path);
      final deviceId = await _getDeviceId();

      final resp = await _backendService.getResponse(
        deviceId: deviceId,
        query: query,
        imageFile: File(compressedFile.path),
        barcode: barcode,
        language: language,
        sessionId: _currentSessionId,
      );

      final newTurn = ConversationTurn(
        query: query,
        response: resp.response,
        timestamp: DateTime.now(),
        imagePath: null,
        language: language.name,
      );

      state = state.copyWith(
        status: AppState.speaking,
        lastResponse: resp.response,
        history: [newTurn, ...state.history],
      );

      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);
      await _ttsService.speak(resp.response, language);

      state = state.copyWith(status: AppState.idle);
    } catch (e) {
      debugPrint('[Error] processTextQuery: $e');
      state = state.copyWith(status: AppState.error);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) state = state.copyWith(status: AppState.idle);
      });
    }
  }

  void stopSpeaking() {
    _ttsService.onAllCompleted = null; // Cancel streaming idle-transition handler
    _ttsService.stop();
    state = state.copyWith(status: AppState.idle);
  }

  void clearResponse() {
    if (state.status == AppState.speaking) {
      _ttsService.stop();
    }
    state = state.copyWith(lastResponse: '', status: AppState.idle);
  }

  /// Press mic to start recording.
  /// Press again while AI is speaking → interrupt (stop TTS, start new recording).
  void toggleListening() {
    switch (state.status) {
      case AppState.listening:
        stopListeningAndProcess();
        break;
      case AppState.speaking:
        // Interrupt: stop TTS and immediately start a new recording.
        stopSpeaking();
        startListening();
        break;
      case AppState.thinking:
        // Already processing — ignore.
        break;
      case AppState.idle:
      case AppState.error:
        startListening();
        break;
    }
  }

  Future<void> switchCamera() async {
    await _cameraService.switchCamera();
    state = state.copyWith();
  }

  Future<void> handleAppResumed() async {
    try {
      await _cameraService.onAppResumed();
      state = state.copyWith();
    } catch (e) {
      debugPrint('[Lifecycle] Camera resume failed: $e');
    }
  }

  Future<void> handleAppPausedOrInactive() async {
    await _cameraService.onAppInactiveOrPaused();
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

  @override
  void dispose() {
    unawaited(_cameraService.dispose());
    unawaited(_barcodeService.dispose());
    _recorder.dispose();
    super.dispose();
  }
}

class _CaptureResult {
  final File? file;
  final String? barcode;
  const _CaptureResult({required this.file, required this.barcode});
}
