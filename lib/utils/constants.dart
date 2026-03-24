import 'package:flutter/material.dart';

class AppConstants {
  static const String appName = 'Sahayak';
  
  // Font sizes
  static const double fontSizeNormal = 18.0;
  static const double fontSizeLarge = 22.0;
  static const double fontSizeExtraLarge = 26.0;
  
  // Colors
  static const Color primaryColor = Color(0xFF1A73E8);
  static const Color backgroundColor = Colors.white;
  static const Color textMainColor = Colors.black87;
  
  // Settings keys
  static const String keyLanguage = 'selected_language';
  static const String keyTextSize = 'text_size_multiplier';
  static const String keyVoiceSpeed = 'voice_speed';
  static const String keyDarkMode = 'dark_mode';
  static const String keyFirstLaunch = 'is_first_launch';
  static const String keyTutorialCompleted = 'tutorial_completed';
}

