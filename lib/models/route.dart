class RouteStep {
  final String title;
  final String instruction;
  final double? distance;
  final int? floor;
  final String type;

  const RouteStep({
    required this.title,
    required this.instruction,
    this.distance,
    this.floor,
    required this.type,
  });

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    return RouteStep(
      title: json['title'] ?? '',
      instruction: json['instruction'] ?? '',
      distance: json['distance'] != null
          ? double.tryParse(json['distance'].toString())
          : null,
      floor: json['floor'] != null
          ? int.tryParse(json['floor'].toString())
          : null,
      type: json['type'] ?? '',
    );
  }
}

class NavigationRoute {
  final double distance;
  final double duration;
  final List<RouteStep> steps;

  const NavigationRoute({
    required this.distance,
    required this.duration,
    required this.steps,
  });

  factory NavigationRoute.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawSteps = json['steps'] as List? ?? [];

    return NavigationRoute(
      distance: double.tryParse(
            json['distance']?.toString() ?? '',
          ) ??
          0,

      duration: double.tryParse(
            json['duration']?.toString() ?? '',
          ) ??
          0,

      steps: rawSteps
          .map(
            (step) => RouteStep.fromJson(
              Map<String, dynamic>.from(step),
            ),
          )
          .toList(),
    );
  }
}