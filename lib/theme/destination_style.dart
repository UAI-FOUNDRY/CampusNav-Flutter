import 'package:flutter/material.dart';
import 'app_colors.dart';

/// The metro "line" colour for a building.
Color lineColorForBuilding(String building) {
  switch (building) {
    case 'Academic Building':
      return AppColors.academic;
    case 'Main Building':
      return AppColors.mainBuilding;
    case 'Hostel':
      return AppColors.hostel;
    case 'Sports Building':
      return AppColors.sports;
    default:
      // Real buildings (Block A, Block B): places carry their line colour
      // (colorForType), so building headings stay neutral.
      return AppColors.ink;
  }
}

/// Text or icon colour that stays readable when drawn ON a line colour.
Color readableOnLine(Color line) =>
    line.computeLuminance() > 0.4 ? AppColors.ink : Colors.white;

/// A line colour that is dark enough to use for icons and text on white.
Color lineInk(Color line) {
  if (line == AppColors.sports) return AppColors.sportsInk;
  if (line.computeLuminance() <= 0.4) return line;
  final hsl = HSLColor.fromColor(line);
  return hsl.withLightness((hsl.lightness - 0.25).clamp(0.0, 1.0)).toColor();
}

/// One "metro line" of places: a name, a colour and the types on it.
class PlaceLine {
  final String name;
  final Color color;
  final IconData icon;
  final List<String> types;

  const PlaceLine(this.name, this.color, this.icon, this.types);
}

/// Every place belongs to one line. The order is the legend's order.
const List<PlaceLine> placeLines = [
  PlaceLine('Classrooms', AppColors.lineClassrooms, Icons.meeting_room, ['hall', 'auditorium']),
  PlaceLine('Labs', AppColors.lineLabs, Icons.science, ['lab']),
  PlaceLine('Library', AppColors.lineLibrary, Icons.local_library, ['library']),
  PlaceLine('Food', AppColors.lineFood, Icons.restaurant, ['cafeteria']),
  PlaceLine('Offices', AppColors.lineOffices, Icons.business_center, ['office']),
  PlaceLine('Facilities', AppColors.lineFacilities, Icons.local_convenience_store, ['facility', 'shop']),
  PlaceLine('Washrooms', AppColors.lineWashrooms, Icons.wc, ['washroom']),
  PlaceLine('Sports', AppColors.lineSports, Icons.sports_soccer, ['sports', 'gym', 'turf']),
  PlaceLine('Hostel', AppColors.lineHostel, Icons.bed, ['hostel']),
  PlaceLine('Other', AppColors.lineOther, Icons.place, []),
];

/// The line a place type is on ("Other" if none).
PlaceLine lineForType(String type) {
  for (final line in placeLines) {
    if (line.types.contains(type)) return line;
  }
  return placeLines.last;
}

/// The colour for a place: its line's colour.
Color colorForType(String type) => lineForType(type).color;

IconData iconForType(String type) {
  switch (type) {
    case 'library':
      return Icons.local_library;
    case 'lab':
      return Icons.science;
    case 'hall':
      return Icons.meeting_room;
    case 'auditorium':
      return Icons.theater_comedy;
    case 'cafeteria':
      return Icons.restaurant;
    case 'office':
      return Icons.business_center;
    case 'hostel':
      return Icons.bed;
    case 'sports':
      return Icons.sports_soccer;
    case 'gym':
      return Icons.fitness_center;
    case 'turf':
      return Icons.grass;
    case 'facility':
      return Icons.local_convenience_store;
    case 'shop':
      return Icons.storefront;
    case 'washroom':
      return Icons.wc;
    default:
      return Icons.place;
  }
}

IconData iconForStep(String type) {
  switch (type) {
    case 'start':
      return Icons.my_location;
    case 'turn_left':
      return Icons.turn_left;
    case 'turn_right':
      return Icons.turn_right;
    case 'enter':
      return Icons.login;
    case 'stairs':
      return Icons.stairs;
    case 'lift':
      return Icons.elevator;
    case 'arrive':
      return Icons.flag;
    default:
      return Icons.arrow_upward;
  }
}

String floorLabel(int floor) => floor == 0 ? 'Ground floor' : 'Floor $floor';

/// Filter chips on the home screen.
const List<String> categories = [
  'All',
  'Labs',
  'Study',
  'Halls',
  'Food',
  'Sports',
  'Admin',
  'Facilities',
  'Washrooms',
  'Hostel',
];

String categoryOfType(String type) {
  switch (type) {
    case 'lab':
      return 'Labs';
    case 'library':
      return 'Study';
    case 'hall':
    case 'auditorium':
      return 'Halls';
    case 'cafeteria':
      return 'Food';
    case 'sports':
    case 'gym':
    case 'turf':
      return 'Sports';
    case 'office':
      return 'Admin';
    case 'hostel':
      return 'Hostel';
    case 'facility':
    case 'shop':
      return 'Facilities';
    case 'washroom':
      return 'Washrooms';
    default:
      return 'Other';
  }
}
