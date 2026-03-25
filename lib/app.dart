import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/settings_provider.dart';
import 'screens/main_screen.dart';
import 'screens/history_screen.dart';

class SahayakApp extends ConsumerWidget {
  const SahayakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    final bool isAppLoading = settings.isLoading;

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
          : const MainScreen(),
      routes: {
        '/main': (context) => const MainScreen(),
        '/history': (context) => const HistoryScreen(),
      },
    );
  }
}
