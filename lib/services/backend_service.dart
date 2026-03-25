import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../models/language.dart';

class BackendService {
  String get _baseUrl => (dotenv.env['BACKEND_URL'] ?? 'http://localhost:8000').trim();

  /// Sends a voice query + optional camera image to the backend.
  /// Returns the AI text response.
  Future<String> getResponse({
    required String deviceId,
    required String query,
    required File? imageFile,
    required Language language,
  }) async {
    final uri = Uri.parse('$_baseUrl/ask');
    final request = http.MultipartRequest('POST', uri);

    request.fields['device_id'] = deviceId;
    request.fields['query'] = query;
    // language.name = lowercase enum name (e.g. 'hindi', 'marathi', 'english')
    // backend capitalizes it to match system_prompt keys
    request.fields['language'] = language.name;

    debugPrint('📤 [Backend] Sending request to $uri');
    debugPrint('📤 [Backend] device_id : $deviceId');
    debugPrint('📤 [Backend] language  : ${language.name}');
    debugPrint('📤 [Backend] query     : "$query"');
    debugPrint('📤 [Backend] has image : ${imageFile != null}');

    if (imageFile != null) {
      request.files.add(await http.MultipartFile.fromPath(
        'image',
        imageFile.path,
      ));
    }

    try {
      final streamedResponse = await request.send().timeout(const Duration(seconds: 60));
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final responseText = (data['response'] as String).trim();
        debugPrint('📥 [Backend] Response: "$responseText"');
        return responseText;
      } else {
        debugPrint('❌ [Backend] Error ${response.statusCode}: ${response.body}');
        throw Exception('Backend error (${response.statusCode})');
      }
    } catch (e) {
      debugPrint('BackendService error: $e');
      rethrow;
    }
  }

  /// Fetches history from the backend.
  Future<List<dynamic>> getHistory(String deviceId) async {
    final uri = Uri.parse('$_baseUrl/history?device_id=$deviceId');
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['items'] as List<dynamic>;
      } else {
        debugPrint('Backend error ${response.statusCode}: ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('BackendService history error: $e');
      return [];
    }
  }

  /// Saves user profile/settings to the backend.
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
      debugPrint('BackendService profile save error: $e');
    }
  }

  /// Fetches user profile/settings from the backend.
  Future<Map<String, dynamic>?> getProfile(String deviceId) async {
    final uri = Uri.parse('$_baseUrl/profile/$deviceId');
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('BackendService profile fetch error: $e');
    }
    return null;
  }
}
