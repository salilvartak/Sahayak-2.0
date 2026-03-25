import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'vad_controller.dart';

typedef OnVoiceStateChanged = void Function(bool isSpeaking);
typedef OnAudioCaptured = void Function(Uint8List audioFrame);

/// PART 2 & 3: Noise Classification + VAD Pipeline
/// PART 10: Observability — logs VAD probabilities and state transitions
class VadPipeline {
  final VadController _vadController;
  final OnVoiceStateChanged onStateChanged;
  final OnAudioCaptured onAudioCaptured;

  static const int sampleRate = 16000;
  static const int frameSizeSamples = 512;
  static const int frameSizeBytes = 1024; // PCM16 = 2 bytes/sample
  static const int silenceFramesRequired = 24; // ~750ms @ 32ms/frame

  bool _isCurrentlySpeaking = false;
  int _silenceFrameCount = 0;
  final List<int> _audioBuffer = [];

  // Observability: log every N frames to avoid flooding the console
  int _frameCount = 0;
  static const int _logEveryNFrames = 50; // ~1.6 seconds

  VadPipeline({
    required VadController vadController,
    required this.onStateChanged,
    required this.onAudioCaptured,
  }) : _vadController = vadController;

  /// Feed raw PCM16 bytes into the pipeline
  void feedAudio(Uint8List data) {
    _audioBuffer.addAll(data);

    while (_audioBuffer.length >= frameSizeBytes) {
      final chunk = Uint8List.fromList(_audioBuffer.sublist(0, frameSizeBytes));
      _audioBuffer.removeRange(0, frameSizeBytes);
      _processFrame(chunk);
    }
  }

  void _processFrame(Uint8List frame) {
    final Int16List pcmData = frame.buffer.asInt16List();

    // --- Noise Classification (RMS energy + Zero Crossing Rate) ---
    double rms = 0.0;
    int zeroCrossings = 0;

    for (int i = 0; i < pcmData.length; i++) {
      final sample = pcmData[i].toDouble() / 32768.0;
      rms += sample * sample;
      if (i > 0 &&
          ((pcmData[i] >= 0 && pcmData[i - 1] < 0) ||
           (pcmData[i] < 0 && pcmData[i - 1] >= 0))) {
        zeroCrossings++;
      }
    }

    rms = sqrt(rms / pcmData.length);
    final zcr = zeroCrossings / pcmData.length;

    // Reject continuous drone (TV, music, environmental noise):
    // - ZCR too low = DC offset / rumble
    // - ZCR too high = broadband hiss
    // - RMS too low = near-silence
    final bool isNoiseRejected = (zcr < 0.02 || zcr > 0.4) || rms < 0.005;

    // --- VAD Probability (logarithmic energy mapping, mocks Silero curve) ---
    double vadProbability = 0.0;
    if (!isNoiseRejected) {
      vadProbability = (log(rms * 100 + 1) / log(10)).clamp(0.0, 1.0);
    }

    // --- Observability ---
    _frameCount++;
    if (_frameCount % _logEveryNFrames == 0) {
      debugPrint('[VAD] prob=${vadProbability.toStringAsFixed(3)} '
          'rms=${rms.toStringAsFixed(4)} zcr=${zcr.toStringAsFixed(3)} '
          'tts=${_vadController.isTtsPlaying} '
          'speaking=$_isCurrentlySpeaking '
          'threshold=${_vadController.currentSpeechThreshold}');
    }

    // --- State Machine ---
    final threshold = _vadController.currentSpeechThreshold;

    if (vadProbability >= threshold) {
      _silenceFrameCount = 0;
      if (!_isCurrentlySpeaking) {
        _isCurrentlySpeaking = true;
        debugPrint('[VAD] Speech START (prob=${vadProbability.toStringAsFixed(3)}, '
            'threshold=$threshold, tts=${_vadController.isTtsPlaying})');
        onStateChanged(true);
      }
      onAudioCaptured(frame);
    } else {
      if (_isCurrentlySpeaking) {
        _silenceFrameCount++;
        onAudioCaptured(frame); // Capture trailing silence for STT context

        if (_silenceFrameCount >= silenceFramesRequired) {
          _isCurrentlySpeaking = false;
          debugPrint('[VAD] Speech END after '
              '${_silenceFrameCount * 32}ms silence');
          onStateChanged(false);
        }
      }
    }
  }

  void reset() {
    _isCurrentlySpeaking = false;
    _silenceFrameCount = 0;
    _audioBuffer.clear();
    debugPrint('[VAD] Pipeline reset');
  }
}
