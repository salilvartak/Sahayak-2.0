import 'package:speech_to_text/speech_to_text.dart';
import '../models/language.dart';

class STTService {
  final SpeechToText _speechToText = SpeechToText();
  bool _isAvailable = false;

  String lastRecognizedWords = '';

  Future<bool> initialize() async {
    _isAvailable = await _speechToText.initialize();
    return _isAvailable;
  }

  Future<void> startListening(
    Language language,
    Function(String) onResult,
  ) async {
    if (!_isAvailable) return;
    lastRecognizedWords = '';
    await _speechToText.listen(
      onResult: (result) {
        lastRecognizedWords = result.recognizedWords;
        onResult(result.recognizedWords);
      },
      localeId: _getLocaleId(language),
    );
  }

  Future<void> stopListening() async {
    await _speechToText.stop();
  }

  String _getLocaleId(Language language) {
    switch (language) {
      case Language.hindi:
        return 'hi_IN';
      case Language.marathi:
        return 'mr_IN';
      case Language.telugu:
        return 'te_IN';
      case Language.english:
        return 'en_US';
    }
  }

  bool get isListening => _speechToText.isListening;
}
