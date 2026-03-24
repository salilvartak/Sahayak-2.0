import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../models/language.dart';

class LanguageState {
  final Language language;
  final bool isLoading;

  LanguageState({
    required this.language,
    this.isLoading = true,
  });

  LanguageState copyWith({
    Language? language,
    bool? isLoading,
  }) {
    return LanguageState(
      language: language ?? this.language,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

final languageProvider = StateNotifierProvider<LanguageNotifier, LanguageState>((ref) {
  return LanguageNotifier();
});

class LanguageNotifier extends StateNotifier<LanguageState> {
  LanguageNotifier() : super(LanguageState(language: Language.hindi)) {
    _loadLanguage();
  }

  Future<void> _loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final String? langCode = prefs.getString(AppConstants.keyLanguage);
    if (langCode != null) {
      final lang = Language.values.firstWhere(
        (l) => l.code == langCode,
        orElse: () => Language.hindi,
      );
      state = state.copyWith(language: lang, isLoading: false);
    } else {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> setLanguage(Language language) async {
    state = state.copyWith(language: language, isLoading: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.keyLanguage, language.code);
  }
}
