import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import '../models/waypoint.dart';

// landmark with name and position
class Landmark {
  final String name;
  final double lat;
  final double lng;
  bool announced = false;

  Landmark({required this.name, required this.lat, required this.lng});
}

class CircuitManager {
  List<Waypoint>  waypoints = [];
  List<Landmark>  landmarks = [];
  int _currentIndex = 0;

  Waypoint? get current  => waypoints.isEmpty || isComplete ? null : waypoints[_currentIndex];
  Waypoint? get next     => waypoints.length > _currentIndex + 1 ? waypoints[_currentIndex + 1] : null;
  bool get isComplete    => _currentIndex >= waypoints.length;
  int  get currentIndex  => _currentIndex;

  Future<void> load({
    String circuitPath  = 'assets/circuit.geojson',
    String landmarksPath = 'assets/landmarks.geojson',
  }) async {
    await _loadCircuit(circuitPath);
    await _loadLandmarks(landmarksPath);
  }

  // ── load circuit (MultiLineString or Points) ──────────────────────────
  Future<void> _loadCircuit(String path) async {
    print('[Circuit] Loading circuit: ' + path);
    String raw;
    try {
      raw = await rootBundle.loadString(path);
    } catch (e) {
      print('[Circuit] ERROR: ' + e.toString());
      return;
    }

    final geojson  = jsonDecode(raw) as Map<String, dynamic>;
    final features = geojson['features'] as List<dynamic>;
    waypoints = [];
    int idx = 0;

    for (final feat in features) {
      final geom  = feat['geometry']  as Map<String, dynamic>;
      final props = feat['properties'] as Map<String, dynamic>? ?? {};
      final gtype = geom['type'] as String;

      if (gtype == 'Point') {
        final c = geom['coordinates'] as List<dynamic>;
        waypoints.add(Waypoint(
          index: idx++,
          name:  props['name']?.toString() ?? props['Name']?.toString() ?? 'Point $idx',
          type:  props['type']?.toString() ?? 'waypoint',
          lat:   (c[1] as num).toDouble(),
          lng:   (c[0] as num).toDouble(),
        ));
      } else if (gtype == 'LineString') {
        final coords = geom['coordinates'] as List<dynamic>;
        for (final c in coords) {
          waypoints.add(Waypoint(
            index: idx++,
            name:  'Point $idx',
            type:  'waypoint',
            lat:   (c[1] as num).toDouble(),
            lng:   (c[0] as num).toDouble(),
          ));
        }
      } else if (gtype == 'MultiLineString') {
        final lines = geom['coordinates'] as List<dynamic>;
        for (final line in lines) {
          for (final c in line as List<dynamic>) {
            waypoints.add(Waypoint(
              index: idx++,
              name:  'Point $idx',
              type:  'waypoint',
              lat:   (c[1] as num).toDouble(),
              lng:   (c[0] as num).toDouble(),
            ));
          }
        }
      }
    }

    waypoints = _deduplicate(waypoints);
    print('[Circuit] ' + waypoints.length.toString() + ' waypoints loaded');
  }

  // ── load landmarks ────────────────────────────────────────────────────
  Future<void> _loadLandmarks(String path) async {
    print('[Circuit] Loading landmarks: ' + path);
    String raw;
    try {
      raw = await rootBundle.loadString(path);
    } catch (e) {
      print('[Circuit] No landmarks file: ' + e.toString());
      return;
    }

    final geojson  = jsonDecode(raw) as Map<String, dynamic>;
    final features = geojson['features'] as List<dynamic>;
    landmarks = [];

    for (final feat in features) {
      final geom  = feat['geometry']  as Map<String, dynamic>;
      final props = feat['properties'] as Map<String, dynamic>? ?? {};
      if (geom['type'] != 'Point') continue;
      final c = geom['coordinates'] as List<dynamic>;
      landmarks.add(Landmark(
        name: props['Name']?.toString() ?? props['name']?.toString() ?? 'Landmark',
        lat:  (c[1] as num).toDouble(),
        lng:  (c[0] as num).toDouble(),
      ));
    }

    print('[Circuit] ' + landmarks.length.toString() + ' landmarks loaded');
    for (final l in landmarks) {
      print('  ' + l.name + ' (' + l.lat.toStringAsFixed(5) + ', ' + l.lng.toStringAsFixed(5) + ')');
    }
  }

  // ── check if user is near any landmark (returns name or null) ─────────
  String? checkLandmarkProximity(double lat, double lng, {double thresholdM = 10.0}) {
    for (final lm in landmarks) {
      if (lm.announced) continue;
      final d = haversine(lat, lng, lm.lat, lm.lng);
      if (d <= thresholdM) {
        lm.announced = true;
        return lm.name;
      }
    }
    return null;
  }

  void resetLandmarkAnnouncements() {
    for (final lm in landmarks) { lm.announced = false; }
  }

  // ── advance ───────────────────────────────────────────────────────────
  void advance() {
    if (isComplete) return;
    print('[Circuit] Reached: ' + (current?.name ?? ''));
    _currentIndex++;
    if (!isComplete) print('[Circuit] Next: ' + (current?.name ?? ''));
    else print('[Circuit] Complete.');
  }

  void reset() { _currentIndex = 0; resetLandmarkAnnouncements(); }

  double distanceToCurrent(double lat, double lng) {
    final wp = current;
    if (wp == null) return double.maxFinite;
    return haversine(lat, lng, wp.lat, wp.lng);
  }

  double bearingToCurrent(double lat, double lng) {
    final wp = current;
    if (wp == null) return 0;
    return bearing(lat, lng, wp.lat, wp.lng);
  }

  List<Waypoint> _deduplicate(List<Waypoint> pts) {
    if (pts.isEmpty) return pts;
    final result = [pts.first];
    for (int i = 1; i < pts.length; i++) {
      final d = haversine(result.last.lat, result.last.lng, pts[i].lat, pts[i].lng);
      if (d > 0.5) result.add(Waypoint(index: result.length, name: pts[i].name, type: pts[i].type, lat: pts[i].lat, lng: pts[i].lng));
    }
    return result;
  }
}

double haversine(double lat1, double lng1, double lat2, double lng2) {
  const R = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = sin(dLat/2)*sin(dLat/2) + cos(_rad(lat1))*cos(_rad(lat2))*sin(dLng/2)*sin(dLng/2);
  return R * 2 * atan2(sqrt(a), sqrt(1-a));
}

double bearing(double lat1, double lng1, double lat2, double lng2) {
  final dLng = _rad(lng2 - lng1);
  final y = sin(dLng) * cos(_rad(lat2));
  final x = cos(_rad(lat1))*sin(_rad(lat2)) - sin(_rad(lat1))*cos(_rad(lat2))*cos(dLng);
  return (_deg(atan2(y, x)) + 360) % 360;
}

double _rad(double d) => d * pi / 180;
double _deg(double r) => r * 180 / pi;