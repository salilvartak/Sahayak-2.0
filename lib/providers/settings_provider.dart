import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../services/backend_service.dart';

class AppSettings {
  final double textSizeMultiplier;
  final String voiceSpeed;
  final bool darkMode;
  final bool tutorialCompleted;
  final bool isFirstLaunch;
  final bool isLoading;

  AppSettings({
    this.textSizeMultiplier = 1.0,
    this.voiceSpeed = 'Normal',
    this.darkMode = false,
    this.tutorialCompleted = false,
    this.isFirstLaunch = true,
    this.isLoading = true,
  });

  AppSettings copyWith({
    double? textSizeMultiplier,
    String? voiceSpeed,
    bool? darkMode,
    bool? tutorialCompleted,
    bool? isFirstLaunch,
    bool? isLoading,
  }) {
    return AppSettings(
      textSizeMultiplier: textSizeMultiplier ?? this.textSizeMultiplier,
      voiceSpeed: voiceSpeed ?? this.voiceSpeed,
      darkMode: darkMode ?? this.darkMode,
      tutorialCompleted: tutorialCompleted ?? this.tutorialCompleted,
      isFirstLaunch: isFirstLaunch ?? this.isFirstLaunch,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  return SettingsNotifier();
});

class SettingsNotifier extends StateNotifier<AppSettings> {
  final BackendService _backendService = BackendService();

  SettingsNotifier() : super(AppSettings()) {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      textSizeMultiplier: prefs.getDouble(AppConstants.keyTextSize) ?? 1.0,
      voiceSpeed: prefs.getString(AppConstants.keyVoiceSpeed) ?? 'Normal',
      darkMode: prefs.getBool(AppConstants.keyDarkMode) ?? false,
      tutorialCompleted: prefs.getBool(AppConstants.keyTutorialCompleted) ?? false,
      isFirstLaunch: prefs.getBool(AppConstants.keyFirstLaunch) ?? true,
      isLoading: false,
    );
  }

  Future<void> setTextSize(double multiplier) async {
    state = state.copyWith(textSizeMultiplier: multiplier);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(AppConstants.keyTextSize, multiplier);
    await _syncWithBackend();
  }

  Future<void> setVoiceSpeed(String speed) async {
    state = state.copyWith(voiceSpeed: speed);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyVoiceSpeed, speed);
    await _syncWithBackend();
  }

  Future<void> setDarkMode(bool value) async {
    state = state.copyWith(darkMode: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyDarkMode, value);
    await _syncWithBackend();
  }

  Future<void> setFirstLaunch(bool value) async {
    state = state.copyWith(isFirstLaunch: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyFirstLaunch, value);
  }

  Future<void> setTutorialCompleted(bool value) async {
    state = state.copyWith(tutorialCompleted: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.keyTutorialCompleted, value);
    await _syncWithBackend();
  }

  Future<void> _syncWithBackend() async {
    final deviceId = await _getDeviceId();
    await _backendService.saveProfile(
      deviceId: deviceId,
      textSizeMultiplier: state.textSizeMultiplier,
      voiceSpeed: state.voiceSpeed,
      darkMode: state.darkMode,
      tutorialCompleted: state.tutorialCompleted,
    );
  }

  Future<String> _getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString('device_id');
    if (id == null) {
      id = DateTime.now().millisecondsSinceEpoch.toString() +
          '-' +
          (1000000 + (DateTime.now().microsecond % 9000000)).toString();
      await prefs.setString('device_id', id);
    }
    return id;
  }
}
