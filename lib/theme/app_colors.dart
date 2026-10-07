import 'package:flutter/material.dart';

/// Every raw colour in the app lives here.
class AppColors {
  AppColors._();

  // Base
  static const platform = Color(0xFFF5F7FA); // app background
  static const ink = Color(0xFF1B2340); // main text
  static const inkMuted = Color(0xFF5B6478); // secondary text
  static const mist = Color(0xFFE4E8EF); // borders, dividers
  static const mapBackground = Color(0xFFEAEFF5);

  // Building lines: one colour per building, like metro lines
  static const academic = Color(0xFF2457E6);
  static const mainBuilding = Color(0xFFE0457B);
  static const hostel = Color(0xFF0E9F8E);
  static const sports = Color(0xFFF2A900);
  static const sportsInk = Color(0xFF8A5F00); // readable amber for icons and text

  // Feedback
  static const success = Color(0xFF0E9F8E);
  static const danger = Color(0xFFC8372D);
}
