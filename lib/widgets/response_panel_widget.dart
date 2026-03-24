import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../providers/language_provider.dart';
import '../providers/settings_provider.dart';
import '../localization/app_localizations.dart';

class ResponsePanelWidget extends ConsumerWidget {
  const ResponsePanelWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationProvider);
    final response = state.lastResponse;
    final status = state.status;
    final languageState = ref.watch(languageProvider);
    final settings = ref.watch(settingsProvider);
    final localizations = AppLocalizations(languageState.language);

    if (response.isEmpty || status == AppState.listening) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 20, bottom: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.3,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white12),
            ),
            child: SingleChildScrollView(
              child: Text(
                response,
                style: TextStyle(
                  fontSize: (20 * settings.textSizeMultiplier).toDouble(),
                  fontWeight: FontWeight.w400,
                  color: Colors.white,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
