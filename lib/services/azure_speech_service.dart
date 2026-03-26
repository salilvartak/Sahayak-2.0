import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AzureSpeechService {
  final _key = dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  final _region = dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';

  // Languages tried in parallel — winner picked by highest confidence.
  static const _candidateLanguages = ['hi-IN', 'mr-IN', 'en-US', 'te-IN', 'ta-IN'];

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
    debugPrint('[Azure] Fetching token from $url');

    final response = await http.post(
      Uri.parse(url),
      headers: {'Ocp-Apim-Subscription-Key': _key},
    );

    if (response.statusCode == 200) {
      _token = response.body;
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
      debugPrint('[Azure] Token obtained');
      return _token!;
    }
    throw Exception(
        'Azure token error ${response.statusCode}: ${response.body}');
  }

  Future<({String language, String transcript, double confidence})?>
      _tryLanguage(
          String token, List<int> audioBytes, String lang) async {
    final url =
        'https://$_region.stt.speech.microsoft.com/speech/recognition/'
        'conversation/cognitiveservices/v1'
        '?language=$lang&format=detailed';

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'audio/wav; codec=audio/pcm; samplerate=16000',
          'Accept': 'application/json',
        },
        body: audioBytes,
      );

      if (response.statusCode != 200) return null;

      final result = jsonDecode(response.body) as Map<String, dynamic>;
      final status = result['RecognitionStatus'] ?? 'Unknown';
      final transcript = result['DisplayText'] as String? ?? '';

      double confidence = 0.0;
      final nBest = result['NBest'] as List<dynamic>?;
      if (nBest != null && nBest.isNotEmpty) {
        confidence = (nBest.first['Confidence'] as num?)?.toDouble() ?? 0.0;
      }

      debugPrint('  [$lang] status=$status '
          'confidence=${confidence.toStringAsFixed(3)} "$transcript"');
      if (status != 'Success') return null;

      return (language: lang, transcript: transcript, confidence: confidence);
    } catch (e) {
      debugPrint('  [$lang] Exception: $e');
      return null;
    }
  }

  Future<({String transcript, String language})> recognize(
      String wavPath) async {
    debugPrint('[Azure] recognize($wavPath)');

    final audioFile = File(wavPath);
    if (!audioFile.existsSync()) {
      throw Exception('Audio file not found: $wavPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    debugPrint('[Azure] File size: ${audioBytes.length} bytes');

    final token = await _getToken();

    final futures = _candidateLanguages
        .map((lang) => _tryLanguage(token, audioBytes, lang))
        .toList();

    final results = await Future.wait(futures, eagerError: false);

    String bestTranscript = '';
    String bestLanguage = 'hi-IN';
    double bestConfidence = -1;

    for (final r in results) {
      if (r == null) continue;
      if (r.confidence > bestConfidence) {
        bestConfidence = r.confidence;
        bestTranscript = r.transcript;
        bestLanguage = r.language;
      }
    }

    debugPrint('[Azure] Winner: $bestLanguage '
        '(confidence=${bestConfidence.toStringAsFixed(3)}) '
        '"$bestTranscript"');

    return (transcript: bestTranscript, language: bestLanguage);
  }
}
