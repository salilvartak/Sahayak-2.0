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
import '../services/history_service.dart';
import '../services/backend_service.dart';
import '../services/azure_speech_service.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

enum AppState { idle, listening, thinking, speaking, error }

class ConversationState {
  final AppState status;
  final String lastResponse;
  final List<ConversationTurn> history;
  final bool isFlashOn;

  ConversationState({
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

final conversationProvider = StateNotifierProvider<ConversationNotifier, ConversationState>((ref) {
  return ConversationNotifier(ref);
});

class ConversationNotifier extends StateNotifier<ConversationState> {
  final Ref _ref;
  final CameraService _cameraService = CameraService();
  final AudioRecorder _recorder = AudioRecorder();
  final AzureSpeechService _azureSpeechService = AzureSpeechService();
  final TTSService _ttsService = TTSService();
  final HistoryService _historyService = HistoryService();
  final BackendService _backendService = BackendService();

  String? _recordingPath;
  Language _detectedLanguage = Language.english;

  ConversationNotifier(this._ref) : super(ConversationState());

  CameraService get cameraService => _cameraService;

  Future<void> initialize() async {
    try {
      // Fetch history from backend instead of local service
      final deviceId = await _getDeviceId();
      final items = await _backendService.getHistory(deviceId);
      
      final history = items.map((item) => ConversationTurn(
        query: item['query'] ?? '',
        response: item['response'] ?? '',
        timestamp: DateTime.tryParse(item['timestamp'] ?? '') ?? DateTime.now(),
        imagePath: item['image_url'], // Use image_url from backend
      )).toList();
      
      state = state.copyWith(history: history);

      // Check and request permissions
      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      if (!cameraStatus.isGranted || !micStatus.isGranted) {
        state = state.copyWith(status: AppState.error);
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(localizations.translate('permission_error'), language);
        return;
      }

      try {
        await _cameraService.initialize();
        // Trigger a state update so the CameraPreviewWidget rebuilds with the new controller
        state = state.copyWith();
      } catch (e) {
        debugPrint('Camera initialization failed: $e');
        state = state.copyWith(status: AppState.error);
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(localizations.translate('camera_error'), language);
        return;
      }
      
      // Welcome message - only if tutorial is already done
      final settings = _ref.read(settingsProvider);
      if (settings.tutorialCompleted) {
        const language = Language.english;
        final localizations = AppLocalizations(language);
        await _ttsService.speak(localizations.translate('welcome_message'), language);
      }
      
      // Final state sync
      state = state.copyWith();
    } catch (e) {
      debugPrint('General initialization error: $e');
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
      debugPrint('Recording Start Error: $e');
      state = state.copyWith(status: AppState.error);
    }
  }

  Future<void> processTextQuery(String query, Language language) async {
    state = state.copyWith(status: AppState.thinking);
    
    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) throw Exception('Camera capture failed');
      
      final compressedFile = await ImageUtils.compressImage(xFile.path);
      final deviceId = await _getDeviceId();
      
      final String response = await _backendService.getResponse(
        deviceId: deviceId,
        query: query,
        imageFile: File(compressedFile.path),
        language: language,
      );

      final newTurn = ConversationTurn(
        query: query,
        response: response,
        timestamp: DateTime.now(),
        imagePath: null,
      );

      final newHistory = [newTurn, ...state.history];

      state = state.copyWith(
        status: AppState.speaking,
        lastResponse: response,
        history: newHistory,
      );

      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);
      await _ttsService.speak(response, language);
      
      state = state.copyWith(status: AppState.idle);
    } catch (e) {
      debugPrint('Error in processTextQuery: $e');
      state = state.copyWith(status: AppState.error);
      Future.delayed(const Duration(seconds: 4), () {
        if (mounted) state = state.copyWith(status: AppState.idle);
      });
    }
  }

  Future<void> stopListeningAndProcess() async {
    final String? path = await _recorder.stop();
    
    state = state.copyWith(status: AppState.thinking);
    
    try {
      final xFile = await _cameraService.captureFrame();
      if (xFile == null) throw Exception('Camera capture failed');
      
      final compressedFile = await ImageUtils.compressImage(xFile.path);
      
      // Send to Azure
      final result = await _azureSpeechService.recognize(path!);
      final transcript = result.transcript.isNotEmpty ? result.transcript : 'What is this?';
      _detectedLanguage = _mapAzureLanguage(result.language);
      
      final deviceId = await _getDeviceId();
      
      // Use detected language
      final String response = await _backendService.getResponse(
        deviceId: deviceId,
        query: transcript,
        imageFile: File(compressedFile.path),
        language: _detectedLanguage,
      );

      final newTurn = ConversationTurn(
        query: transcript,
        response: response,
        timestamp: DateTime.now(),
        imagePath: null, // We don't save locally anymore
      );

      final newHistory = [newTurn, ...state.history];

      state = state.copyWith(
        status: AppState.speaking,
        lastResponse: response,
        history: newHistory,
      );

      final settings = _ref.read(settingsProvider);
      _ttsService.setSpeed(settings.voiceSpeed);
      await _ttsService.speak(response, _detectedLanguage);
      
      state = state.copyWith(status: AppState.idle);
    } catch (e, stackTrace) {
      debugPrint('Error in stopListeningAndProcess: $e');
      debugPrint('Stack trace: $stackTrace');
      
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

  void stopSpeaking() {
    _ttsService.stop();
    state = state.copyWith(status: AppState.idle);
  }

  void clearResponse() {
    if (state.status == AppState.speaking) {
      _ttsService.stop();
    }
    state = state.copyWith(
      lastResponse: '',
      status: AppState.idle,
    );
  }

  void toggleListening() {
    switch (state.status) {
      case AppState.listening:
        stopListeningAndProcess();
        break;
      case AppState.speaking:
        stopSpeaking();
        startListening();
        break;
      case AppState.thinking:
        // Already processing, ignore tap
        break;
      case AppState.idle:
      case AppState.error:
      default:
        startListening();
        break;
    }
  }

  Future<void> switchCamera() async {
    await _cameraService.switchCamera();
    // Force a rebuild to refresh the camera preview
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
      // Generate a simple UUID-like string without adding a package
      id = DateTime.now().millisecondsSinceEpoch.toString() +
          '-' +
          (1000000 + (DateTime.now().microsecond % 9000000)).toString();
      await prefs.setString('device_id', id);
    }
    debugPrint('Sahayak Device ID: $id');
    return id;
  }

  Language _mapAzureLanguage(String azureCode) {
    if (azureCode.toLowerCase().contains('hi')) return Language.hindi;
    if (azureCode.toLowerCase().contains('mr')) return Language.marathi;
    if (azureCode.toLowerCase().contains('te')) return Language.telugu;
    return Language.english;
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _recorder.dispose();
    super.dispose();
  }
}
