class VadController {
  bool _isTtsPlaying = false;

  // Normal speech threshold
  static const double normalThreshold = 0.65;
  // Raised threshold during TTS — hardware AEC handles echo cancellation,
  // but we require stronger confidence to avoid any residual leakage.
  static const double ttsActiveThreshold = 0.85;

  void onTtsStarted() {
    _isTtsPlaying = true;
  }

  void onTtsStopped() {
    // 400ms delay to flush hardware audio buffers after TTS ends
    Future.delayed(const Duration(milliseconds: 400), () {
      _isTtsPlaying = false;
    });
  }

  /// Always allow VAD — hardware AEC filters TTS echo.
  /// Software gate is replaced by a raised threshold during TTS playback.
  bool shouldProcessVad() => true;

  /// Returns the speech probability threshold appropriate for current state.
  double get currentSpeechThreshold =>
      _isTtsPlaying ? ttsActiveThreshold : normalThreshold;

  bool get isTtsPlaying => _isTtsPlaying;
}
