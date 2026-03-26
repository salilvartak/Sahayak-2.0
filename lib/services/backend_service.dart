import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import '../models/language.dart';

/// Response object that carries both the text and the interaction ID
/// (needed for context-aware follow-ups and interruption handling).
class BackendResponse {
  final String response;
  final String interactionId;
  const BackendResponse({required this.response, required this.interactionId});
}

/// PART 7: Context-aware backend payload
/// PART 8: Network resilience — retry with exponential backoff + graceful fallback
class BackendService {
  String get _baseUrl =>
      (dotenv.env['BACKEND_URL'] ?? 'http://localhost:8000').trim();

  static const int _maxRetries = 3;
  static const String _fallbackMessage =
      "I'm having trouble connecting. Please try again.";

  /// Send a voice query to the backend with interrupt context and retry logic.
  Future<BackendResponse> getResponse({
    required String deviceId,
    required String query,
    required File? imageFile,
    required Language language,
    String sessionId = 'default',
    bool wasInterruption = false,
    String partialResponse = '',
    String previousIntent = '',
    String? barcode,
  }) async {
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      if (attempt > 0) {
        // Exponential backoff: 2s, 4s
        final delayMs = 2000 * (1 << (attempt - 1));
        debugPrint('[Backend] Retry $attempt/${_maxRetries - 1} after ${delayMs}ms');
        await Future.delayed(Duration(milliseconds: delayMs));
      }

      try {
        final uri = Uri.parse('$_baseUrl/ask');
        final request = http.MultipartRequest('POST', uri);

        request.fields['device_id'] = deviceId;
        request.fields['session_id'] = sessionId;
        request.fields['query'] = query;
        request.fields['language'] = language.name;
        request.fields['was_interruption'] = wasInterruption.toString();
        request.fields['partial_response'] = partialResponse;
        request.fields['previous_intent'] = previousIntent;
        if (barcode != null && barcode.isNotEmpty) {
          request.fields['barcode'] = barcode;
        }

        debugPrint('[Backend] Attempt ${attempt + 1}/$_maxRetries '
            'query="${query.substring(0, query.length.clamp(0, 60))}" '
            'interruption=$wasInterruption');

        if (imageFile != null) {
          request.files.add(await http.MultipartFile.fromPath(
            'image',
            imageFile.path,
          ));
        }

        final streamedResponse =
            await request.send().timeout(const Duration(seconds: 60));
        final response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final text = ((data['response'] as String?) ?? '').trim();
          final iid = (data['interaction_id'] as String?) ?? '';
          debugPrint('[Backend] OK — ${text.length} chars, id=$iid');
          return BackendResponse(response: text, interactionId: iid);
        } else if (response.statusCode == 429 ||
            response.statusCode >= 500) {
          // Transient error — retry
          debugPrint('[Backend] Transient error ${response.statusCode}');
          continue;
        } else {
          // Non-retryable client error
          throw Exception(
              'Backend error (${response.statusCode}): ${response.body}');
        }
      } on TimeoutException catch (e) {
        debugPrint('[Backend] Timeout on attempt ${attempt + 1}: $e');
        // Retry on timeout
      } on SocketException catch (e) {
        debugPrint('[Backend] Network error on attempt ${attempt + 1}: $e');
        // Retry on network errors
      } catch (e) {
        debugPrint('[Backend] Unexpected error on attempt ${attempt + 1}: $e');
        // Don't retry unexpected errors
        rethrow;
      }
    }

    debugPrint('[Backend] All $maxRetries retries exhausted — using fallback');
    return const BackendResponse(
        response: _fallbackMessage, interactionId: '');
  }

  static const int maxRetries = _maxRetries;

  /// Stream a voice query response as SSE tokens from /ask/stream.
  /// Yields plain-text chunks as they arrive; caller splits at sentence
  /// boundaries and feeds each sentence to TTSService.speakStreaming().
  Stream<String> streamResponse({
    required String deviceId,
    required String query,
    required File? imageFile,
    required Language language,
    String sessionId = 'default',
    bool wasInterruption = false,
    String partialResponse = '',
    String previousIntent = '',
    String? barcode,
  }) async* {
    final uri = Uri.parse('$_baseUrl/ask/stream');
    final request = http.MultipartRequest('POST', uri);

    request.fields['device_id'] = deviceId;
    request.fields['session_id'] = sessionId;
    request.fields['query'] = query;
    request.fields['language'] = language.name;
    request.fields['was_interruption'] = wasInterruption.toString();
    request.fields['partial_response'] = partialResponse;
    request.fields['previous_intent'] = previousIntent;
    if (barcode != null && barcode.isNotEmpty) {
      request.fields['barcode'] = barcode;
    }

    if (imageFile != null) {
      request.files.add(
        await http.MultipartFile.fromPath('image', imageFile.path),
      );
    }

    debugPrint('[Backend/stream] Starting SSE stream for query="${query.substring(0, query.length.clamp(0, 60))}"');

    final streamedResponse =
        await request.send().timeout(const Duration(seconds: 15));

    if (streamedResponse.statusCode != 200) {
      throw Exception(
          'Stream error ${streamedResponse.statusCode}');
    }

    final lines = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data: ')) continue;
      final data = line.substring(6);
      if (data == '[DONE]') break;
      if (data.isNotEmpty) yield data;
    }
  }

  /// Fetch conversation history for a device.
  Future<List<dynamic>> getHistory(String deviceId) async {
    final uri = Uri.parse('$_baseUrl/history?device_id=$deviceId');
    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return (data['items'] as List<dynamic>?) ?? [];
      }
      debugPrint('[Backend] History error ${response.statusCode}');
    } catch (e) {
      debugPrint('[Backend] History fetch error: $e');
    }
    return [];
  }

  Future<void> saveProfile({
    required String deviceId,
    required double textSizeMultiplier,
    required String voiceSpeed,
    required bool darkMode,
    required bool tutorialCompleted,
  }) async {
    final uri = Uri.parse('$_baseUrl/profile');
    try {
      await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': deviceId,
          'text_size_multiplier': textSizeMultiplier,
          'voice_speed': voiceSpeed,
          'dark_mode': darkMode,
          'tutorial_completed': tutorialCompleted,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[Backend] Profile save error: $e');
    }
  }

  Future<Map<String, dynamic>?> getProfile(String deviceId) async {
    final uri = Uri.parse('$_baseUrl/profile/$deviceId');
    try {
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Backend] Profile fetch error: $e');
    }
    return null;
  }
}
