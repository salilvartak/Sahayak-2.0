import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AzureSpeechService {
  final _key = dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  final _region = dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';

  // English words that Azure Hindi-STT commonly transcribes into Devanagari.
  // When the majority of words in a transcript match this set, the user was
  // almost certainly speaking English and the LID misfired.
  static const _devanagariEnglish = {
    // wh-questions
    'व्हॉट', 'व्हाट', 'व्हट', 'हाउ', 'वाय', 'व्हाइ',
    'वेयर', 'व्हेन', 'व्हू', 'व्हिच', 'विच', 'व्हो',
    // to-be / auxiliaries
    'इज़', 'इज', 'इस', 'आर', 'वाज़', 'वाज', 'वेर',
    'हैव', 'हैज़', 'हैज', 'डू', 'डज़', 'डज', 'डिड',
    'कैन', 'कांट', 'विल', 'वुड', 'शुड', 'कुड', 'मस्ट',
    // pronouns / articles
    'दिस', 'देट', 'देज़', 'देज', 'देयर', 'देम', 'दे',
    'आई', 'माय', 'मी', 'यू', 'युअर', 'वी', 'अवर', 'अस',
    'धी', 'द', 'अ', 'एन',
    // conjunctions / prepositions
    'एंड', 'ऑर', 'नॉट', 'इन', 'ऑन', 'एट', 'फॉर', 'विद',
    // common queries / greetings
    'ओके', 'हेलो', 'हाय', 'येस', 'नो', 'नोप',
    'प्लीज़', 'प्लीज', 'थैंक्यू', 'थैंक', 'सॉरी',
    'शो', 'टेल', 'गिव', 'हेल्प',
  };

  /// Returns true when a Devanagari transcript is mostly English words that
  /// the STT has phonetically transcribed (e.g. "व्हॉट इज़ दिस" → "What is this?").
  static bool _isTransliteratedEnglish(String transcript) {
    final words = transcript
        .replaceAll(RegExp(r'[।?,!।॥]'), '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return false;
    final matches =
        words.where((w) => _devanagariEnglish.contains(w)).length;
    // Majority-vote: more than half the words are known English transliterations
    return matches * 2 > words.length;
  }

  String? _token;
  DateTime? _tokenExpiry;

  Future<String> _getToken() async {
    if (_token != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _token!;
    }

    final url =
        'https://$_region.api.cognitive.microsoft.com/sts/v1.0/issueToken';
    debugPrint('[Azure STT] Fetching token');

    final response = await http.post(
      Uri.parse(url),
      headers: {'Ocp-Apim-Subscription-Key': _key},
    );

    if (response.statusCode == 200) {
      _token = response.body;
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
      debugPrint('[Azure STT] Token obtained');
      return _token!;
    }
    throw Exception(
        'Azure token error ${response.statusCode}: ${response.body}');
  }

  /// Single LID call — detects language AND transcribes in one request (~5x
  /// faster than the previous 5-parallel-calls approach).
  Future<({String transcript, String language})> recognize(
      String wavPath) async {
    debugPrint('[Azure STT] recognize($wavPath)');

    final audioFile = File(wavPath);
    if (!audioFile.existsSync()) {
      throw Exception('Audio file not found: $wavPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    debugPrint('[Azure STT] File size: ${audioBytes.length} bytes');

    final token = await _getToken();

    final url = Uri(
      scheme: 'https',
      host: '$_region.stt.speech.microsoft.com',
      path: '/speech/recognition/conversation/cognitiveservices/v1',
      queryParameters: {
        'language': 'hi-IN',
        'lid': 'mr-IN,en-US,te-IN,ta-IN',
        'format': 'detailed',
      },
    );

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'audio/wav; codec=audio/pcm; samplerate=16000',
              'Accept': 'application/json',
            },
            body: audioBytes,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint(
            '[Azure STT] Error ${response.statusCode}: ${response.body}');
        return (transcript: '', language: 'hi-IN');
      }

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final status = result['RecognitionStatus'] as String? ?? 'Unknown';
      final transcript = result['DisplayText'] as String? ?? '';
      // 'Language' field is populated when lid= parameter is used
      final detectedLang = result['Language'] as String? ?? 'hi-IN';

      debugPrint(
          '[Azure STT] status=$status lang=$detectedLang "$transcript"');

      if (status != 'Success') {
        return (transcript: '', language: detectedLang);
      }

      // If LID returned a Devanagari language but the transcript looks like
      // transliterated English (e.g. "व्हॉट इज़ दिस" = "What is this?"),
      // override to en-US so the AI responds in English.
      if ((detectedLang == 'hi-IN' || detectedLang == 'mr-IN') &&
          _isTransliteratedEnglish(transcript)) {
        debugPrint('[Azure STT] Overriding $detectedLang → en-US '
            '(transliterated English detected)');
        return (transcript: transcript, language: 'en-US');
      }

      return (transcript: transcript, language: detectedLang);
    } catch (e) {
      debugPrint('[Azure STT] Exception: $e');
      return (transcript: '', language: 'hi-IN');
    }
  }
}
