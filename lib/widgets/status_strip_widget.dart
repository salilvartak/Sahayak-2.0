import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../models/language.dart';
import '../localization/app_localizations.dart';


class StatusStripWidget extends ConsumerWidget {
  const StatusStripWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(conversationProvider).status;
    const language = Language.english;
    final localizations = AppLocalizations(language);

    String statusText = '';
    switch (status) {
      case AppState.idle:
        statusText = localizations.translate('press_to_speak');
        break;
      case AppState.listening:
        statusText = localizations.translate('listening');
        break;
      case AppState.thinking:
        statusText = localizations.translate('thinking');
        break;
      case AppState.speaking:
        statusText = localizations.translate('speaking');
        break;
      case AppState.error:
        statusText = localizations.translate('error_occurred');
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
      width: double.infinity,
      color: Colors.transparent,
      child: Text(
        statusText,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: status == AppState.error ? Colors.redAccent : Colors.white,
          shadows: [
            Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2)),
          ],
        ),
      ),
    );
  }
}
