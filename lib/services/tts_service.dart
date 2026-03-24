import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/language.dart';

final ttsServiceProvider = Provider((ref) => TTSService());

class TTSService {
  final FlutterTts _flutterTts = FlutterTts();
  double _rate = 0.5;

  Future<void> speak(String text, Language language) async {
    await _flutterTts.setLanguage(language.code == 'en' ? 'en-US' : _getLanguageCode(language));
    await _flutterTts.setSpeechRate(_rate);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.speak(text);
  }

  String _getLanguageCode(Language language) {
    switch (language) {
      case Language.hindi:
        return 'hi-IN';
      case Language.marathi:
        return 'mr-IN';
      case Language.telugu:
        return 'te-IN';
      case Language.english:
        return 'en-US';
    }
  }

  Future<void> stop() async {
    await _flutterTts.stop();
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
