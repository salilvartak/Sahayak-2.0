import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    // Handle missing .env file gracefully for development
    debugPrint("Warning: .env file not found or could not be loaded.");
  }

  runApp(
    const ProviderScope(
      child: SahayakApp(),
    ),
  );
}
