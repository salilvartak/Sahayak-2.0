import 'dart:io';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/conversation_turn.dart';

class HistoryService {
  static const String _key = 'conversation_history';

  Future<void> saveHistory(List<ConversationTurn> history) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(history.map((t) => t.toJson()).toList());
    await prefs.setString(_key, encoded);
  }

  Future<List<ConversationTurn>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final String? encoded = prefs.getString(_key);
    if (encoded == null) return [];
    
    try {
      final List<dynamic> decoded = jsonDecode(encoded);
      return decoded.map((item) => ConversationTurn.fromJson(item)).toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);

    // Also clear saved images
    try {
      final directory = await getApplicationDocumentsDirectory();
      final historyDir = Directory(p.join(directory.path, 'history_images'));
      if (await historyDir.exists()) {
        await historyDir.delete(recursive: true);
      }
    } catch (e) {
      // Ignore errors during delete
    }
  }
}
