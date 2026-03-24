import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/settings_provider.dart';
import 'providers/language_provider.dart';
import 'screens/language_selection_screen.dart';
import 'screens/main_screen.dart';
import 'screens/main_screen.dart';
import 'screens/history_screen.dart';

class SahayakApp extends ConsumerWidget {
  const SahayakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final languageState = ref.watch(languageProvider);

    final bool isAppLoading = settings.isLoading || languageState.isLoading;

    return MaterialApp(
      title: 'Sahayak',
      theme: ThemeData(
        useMaterial3: true,
        primaryColor: Colors.blue,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        scaffoldBackgroundColor: Colors.white,
      ),
      darkTheme: settings.darkMode ? ThemeData.dark(useMaterial3: true) : null,
      themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
      debugShowCheckedModeBanner: false,
      home: isAppLoading 
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (settings.isFirstLaunch ? const LanguageSelectionScreen() : const MainScreen()),
      routes: {
        '/language_selection': (context) => const LanguageSelectionScreen(),
        '/main': (context) => const MainScreen(),
        '/history': (context) => const HistoryScreen(),
      },
    );
  }
}
