import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/language.dart';

final ttsServiceProvider = Provider((ref) => TTSService());

/// PART 6: Streaming TTS with sentence-boundary splitting, backpressure
/// control, SSML prosody, and immediate interrupt support.
class TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  double _rate = 0.5;

  final Queue<String> _ttsQueue = Queue();
  static const int _maxQueueSize = 3;
  bool _isProcessing = false;
  bool _isStopped = false;

  /// Fires when a sentence starts playing (used to transition to streaming state)
  VoidCallback? onSentenceStarted;
  /// Fires when the last queued sentence finishes playing
  VoidCallback? onAllCompleted;

  TTSService() {
    _flutterTts.setCompletionHandler(() {
      _isProcessing = false;
      if (_isStopped) return;
      debugPrint('[TTS] Sentence done. Remaining: ${_ttsQueue.length}');
      if (_ttsQueue.isEmpty) {
        debugPrint('[TTS] All sentences spoken');
        onAllCompleted?.call();
      } else {
        _processNextInQueue();
      }
    });

    _flutterTts.setCancelHandler(() {
      _isProcessing = false;
      debugPrint('[TTS] Cancelled');
    });

    _flutterTts.setErrorHandler((msg) {
      debugPrint('[TTS] Error: $msg');
      _isProcessing = false;
      // Attempt to continue queue despite error
      if (!_isStopped && _ttsQueue.isNotEmpty) {
        _processNextInQueue();
      }
    });
  }

  /// Speak text sentence-by-sentence with backpressure queue control.
  /// Suitable for streaming AI responses as they arrive.
  Future<void> speakStreaming(String text, Language language) async {
    _isStopped = false;
    await _flutterTts.setLanguage(_getLanguageCode(language));
    await _flutterTts.setSpeechRate(_rate);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(false); // Non-blocking

    final sentences = _splitIntoSentences(text);
    debugPrint('[TTS] Queuing ${sentences.length} sentences for: "${text.substring(0, text.length.clamp(0, 50))}..."');

    for (final sentence in sentences) {
      if (_isStopped) break;

      // Backpressure: drop oldest sentence if queue overflows
      if (_ttsQueue.length >= _maxQueueSize) {
        final dropped = _ttsQueue.removeFirst();
        debugPrint('[TTS] Queue overflow — dropped: "${dropped.substring(0, dropped.length.clamp(0, 30))}..."');
      }
      _ttsQueue.add(sentence);
    }

    if (!_isProcessing) {
      _processNextInQueue();
    }
  }

  void _processNextInQueue() {
    if (_isStopped || _ttsQueue.isEmpty || _isProcessing) return;
    _isProcessing = true;
    final sentence = _ttsQueue.removeFirst();
    debugPrint('[TTS] Speaking: "${sentence.substring(0, sentence.length.clamp(0, 60))}"');
    onSentenceStarted?.call();
    _flutterTts.speak(sentence);
  }

  /// Blocking speak for one-off utility messages (welcome, tutorial, errors).
  Future<void> speak(String text, Language language) async {
    _isStopped = false;
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setLanguage(_getLanguageCode(language));
    await _flutterTts.setSpeechRate(_rate);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(text);
  }

  /// Immediately stop all speech and clear the queue.
  /// Called on interruptions to halt AI response.
  Future<void> stop() async {
    _isStopped = true;
    _ttsQueue.clear();
    _isProcessing = false;
    debugPrint('[TTS] Stopped — queue cleared');
    await _flutterTts.stop();
  }

  bool get isIdle => _ttsQueue.isEmpty && !_isProcessing;

  /// Split text at sentence boundaries: ., !, ?
  List<String> _splitIntoSentences(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return [];

    // Split after .!? followed by whitespace (preserves the punctuation)
    final parts = trimmed.split(RegExp(r'(?<=[.!?])\s+'));
    final sentences = <String>[];
    for (final part in parts) {
      final s = part.trim();
      if (s.isNotEmpty) sentences.add(s);
    }
    return sentences.isEmpty ? [trimmed] : sentences;
  }

  String _getLanguageCode(Language language) {
    return language.bcp47;
  }

  void setSpeed(String speed) {
    switch (speed) {
      case 'Slow':
        _rate = 0.4;
        break;
      case 'Normal':
        _rate = 0.5;
        break;
      case 'Fast':
        _rate = 0.6;
        break;
    }
  }
}
