// lib/models/waypoint.dart

class Waypoint {
  final int    index;
  final String name;
  final String type;   // "monument" | "waypoint"
  final double lat;
  final double lng;

  const Waypoint({
    required this.index,
    required this.name,
    required this.type,
    required this.lat,
    required this.lng,
  });

  @override
  String toString() => 'Waypoint($index: $name [$type] $lat,$lng)';
}
