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
      return AppColors.academic;
  }
}

/// Text or icon colour that stays readable when drawn ON a line colour.
Color readableOnLine(Color line) =>
    line == AppColors.sports ? AppColors.ink : Colors.white;

/// A line colour that is dark enough to use for icons and text on white.
Color lineInk(Color line) =>
    line == AppColors.sports ? AppColors.sportsInk : line;

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
    default:
      return 'Other';
  }
}
