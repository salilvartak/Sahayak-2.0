import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AzureSpeechService {
  final _key = dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  final _region = dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';

  // Languages tried in parallel – order doesn't matter for detection,
  // but hi-IN listed first in debug output for readability.
  static const _candidateLanguages = ['hi-IN', 'mr-IN', 'en-US'];

  String? _token;
  DateTime? _tokenExpiry;

  // ─── Token Management ────────────────────────────────────────────────
  Future<String> _getToken() async {
    debugPrint('🔑 [Azure] region=$_region | key=${_key.isEmpty ? "MISSING!" : "${_key.substring(0, 6)}..."}');

    if (_token != null && _tokenExpiry != null && DateTime.now().isBefore(_tokenExpiry!)) {
      debugPrint('🔑 [Azure] Using cached token');
      return _token!;
    }

    final url = 'https://$_region.api.cognitive.microsoft.com/sts/v1.0/issueToken';
    debugPrint('🔑 [Azure] Fetching token from $url');

    final response = await http.post(
      Uri.parse(url),
      headers: {'Ocp-Apim-Subscription-Key': _key},
    );

    debugPrint('🔑 [Azure] Token HTTP ${response.statusCode}');

    if (response.statusCode == 200) {
      _token = response.body;
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 9));
      debugPrint('✅ [Azure] Token obtained');
      return _token!;
    }
    debugPrint('❌ [Azure] Token FAILED: ${response.statusCode} → ${response.body}');
    throw Exception('Azure token error ${response.statusCode}: ${response.body}');
  }

  // ─── Single-language recognition attempt ────────────────────────────
  Future<({String language, String transcript, double confidence, String status})?>
      _tryLanguage(String token, List<int> audioBytes, String lang) async {
    final url =
        'https://$_region.stt.speech.microsoft.com/speech/recognition/conversation/cognitiveservices/v1'
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

      if (response.statusCode != 200) {
        debugPrint('⚠️ [$lang] HTTP ${response.statusCode} → ${response.body}');
        return null;
      }

      final Map<String, dynamic> result = jsonDecode(response.body);
      final String status = result['RecognitionStatus'] ?? 'Unknown';
      final String transcript = result['DisplayText'] ?? '';

      // `format=detailed` gives us NBest with Confidence scores
      double confidence = 0.0;
      final nBest = result['NBest'] as List<dynamic>?;
      if (nBest != null && nBest.isNotEmpty) {
        confidence = (nBest.first['Confidence'] as num?)?.toDouble() ?? 0.0;
      }

      debugPrint('  [$lang] status=$status | confidence=${confidence.toStringAsFixed(3)} | "$transcript"');
      return (language: lang, transcript: transcript, confidence: confidence, status: status);
    } catch (e) {
      debugPrint('  [$lang] Exception: $e');
      return null;
    }
  }

  // ─── Main entry point ─────────────────────────────────────────────
  Future<({String transcript, String language})> recognize(String wavPath) async {
    debugPrint('🎙️ [Azure] recognize($wavPath)');

    // Validate file
    final audioFile = File(wavPath);
    if (!audioFile.existsSync()) {
      debugPrint('❌ [Azure] File not found: $wavPath');
      throw Exception('Audio file not found: $wavPath');
    }
    final audioBytes = await audioFile.readAsBytes();
    debugPrint('🎙️ [Azure] File size: ${audioBytes.length} bytes');
    if (audioBytes.length < 1000) {
      debugPrint('⚠️ [Azure] Very small file — mic may not have recorded properly');
    }

    final token = await _getToken();

    // Run all candidate languages in PARALLEL
    debugPrint('🎙️ [Azure] Running parallel recognition for: $_candidateLanguages');
    final futures = _candidateLanguages
        .map((lang) => _tryLanguage(token, audioBytes, lang))
        .toList();

    final results = await Future.wait(futures, eagerError: false);

    // Pick the result with highest confidence among successes
    String bestTranscript = '';
    String bestLanguage = 'hi-IN'; // sensible default for Sahayak's audience
    double bestConfidence = -1;

    for (final r in results) {
      if (r == null) continue;
      if (r.status == 'Success' && r.confidence > bestConfidence) {
        bestConfidence = r.confidence;
        bestTranscript = r.transcript;
        bestLanguage = r.language;
      }
    }

    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    debugPrint('✅ [Azure] Winner       : $bestLanguage (confidence=${bestConfidence.toStringAsFixed(3)})');
    debugPrint('✅ [Azure] Transcript   : "$bestTranscript"');
    debugPrint('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    if (bestTranscript.isEmpty) {
      debugPrint('⚠️ [Azure] No successful recognition in any language. Results: $results');
    }

    return (transcript: bestTranscript, language: bestLanguage);
  }
}
