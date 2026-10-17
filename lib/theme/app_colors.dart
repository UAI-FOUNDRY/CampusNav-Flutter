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

  // Place lines: one colour per kind of place, like metro lines.
  // Every pin, route line and icon for a place uses its line colour.
  static const lineClassrooms = Color(0xFF2457E6); // blue
  static const lineLabs = Color(0xFF7C3AED); // purple
  static const lineLibrary = Color(0xFFC2410C); // burnt orange
  static const lineFood = Color(0xFFE11D48); // red
  static const lineOffices = Color(0xFF0E8F80); // teal
  static const lineFacilities = Color(0xFFDB2777); // magenta
  static const lineWashrooms = Color(0xFF64748B); // slate
  static const lineSports = Color(0xFF2F9E44); // green
  static const lineHostel = Color(0xFF0891B2); // cyan
  static const lineOther = Color(0xFF475569); // grey

  // Feedback
  static const success = Color(0xFF0E9F8E);
  static const danger = Color(0xFFC8372D);
}
