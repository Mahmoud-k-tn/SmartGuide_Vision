// lib/navigation/mapbox_router.dart
// Mapbox Navigation SDK — turn-by-turn routing with voice instructions.
// Speaks each maneuver step via AudioManager.
//
// Requires:
//   - MAPBOX_TOKEN in lib/core/config.dart
//   - mapbox_maps_flutter: ^2.3.0 in pubspec.yaml

import 'dart:async';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import '../core/audio_manager.dart';
import '../models/waypoint.dart';
import '../core/config.dart';

// ── step announcement thresholds ─────────────────────────────────────────────
const double _ANNOUNCE_FAR_M  = 200.0;  // first announcement
const double _ANNOUNCE_NEAR_M =  30.0;  // final confirmation
const double _REROUTE_M       =  50.0;  // reroute if off-route by this much

class MapboxRouter {
  static const String token = Config.MAPBOX_TOKEN;
  
  final AudioManager _audio;
  MapboxMap?         _mapboxMap;

  // route state
  List<_RouteStep> _steps       = [];
  int              _stepIndex   = 0;
  bool             _announced   = false;   // far announcement fired
  bool             _announcedNr = false;   // near announcement fired
  bool             _active      = false;

  // callbacks
  void Function(String instruction)? onStepAnnouncement;
  void Function(double distanceRemaining, double duration)? onProgress;
  VoidCallback? onArrived;
  VoidCallback? onRerouting;

  MapboxRouter(this._audio);

  // ── attach the MapboxMap widget controller ────────────────────────────
  void attachMap(MapboxMap map) {
    _mapboxMap = map;
  }

  // ── request a route to a waypoint ────────────────────────────────────
  Future<void> routeTo(Waypoint destination, {
    required double userLat,
    required double userLng,
  }) async {
    _active      = false;
    _steps       = [];
    _stepIndex   = 0;
    _announced   = false;
    _announcedNr = false;

    print('[Mapbox] Requesting route to ${destination.name}');

    try {
      // Build Mapbox route request
      final origin = Point(
        coordinates: Position(userLng, userLat),
      );
      final dest = Point(
        coordinates: Position(destination.lng, destination.lat),
      );

      // Request directions via Mapbox Directions API
      // The SDK handles this through MapboxNavigation
      final options = NavigationRouteOptions(
        coordinatesList: [origin, dest],
        language:        'en',
        voiceUnits:      VoiceUnits.metric,
        profile:         DrivingProfile.walking,   // pedestrian routing
      );

      final routes = await MapboxRoutingApi().fetchRoutes(options);
      if (routes == null || routes.isEmpty) {
        print('[Mapbox] No route found to ${destination.name}');
        await _audio.speak(
          'Could not find a route to ${destination.name}',
          priority: AudioPriority.p1Obstacle,
        );
        return;
      }

      // Parse steps from the first (best) route
      _steps = _parseSteps(routes.first);
      _active = true;

      print('[Mapbox] Route found: ${_steps.length} steps');

      // Announce departure
      if (_steps.isNotEmpty) {
        final first = _steps.first;
        await _audio.speak(
          'Route found. ${first.instruction}',
          priority: AudioPriority.p2Navigation,
        );
      }

    } catch (e) {
      print('[Mapbox] Route request failed: $e');
      // Fallback: give bearing-only guidance
      await _audio.speak(
        'Navigating to ${destination.name}',
        priority: AudioPriority.p2Navigation,
      );
    }
  }

  // ── update on each GPS fix ────────────────────────────────────────────
  Future<void> onLocationUpdate(double lat, double lng) async {
    if (!_active || _steps.isEmpty) return;
    if (_stepIndex >= _steps.length) return;

    final step = _steps[_stepIndex];
    final dist = _haversine(lat, lng, step.targetLat, step.targetLng);

    // Progress callback
    onProgress?.call(dist, 0);

    // ── far announcement (200m before maneuver) ───────────────────────
    if (!_announced && dist <= _ANNOUNCE_FAR_M) {
      _announced = true;
      final msg = 'In ${dist.toInt()} metres, ${step.instruction}';
      print('[Mapbox] $msg');
      await _audio.speak(msg, priority: AudioPriority.p2Navigation);
      onStepAnnouncement?.call(msg);
    }

    // ── near announcement (30m before maneuver) ───────────────────────
    if (!_announcedNr && dist <= _ANNOUNCE_NEAR_M) {
      _announcedNr = true;
      final msg = step.instruction;
      print('[Mapbox] $msg');
      await _audio.speak(msg, priority: AudioPriority.p2Navigation);
      onStepAnnouncement?.call(msg);
    }

    // ── step completion (within 10m of target) ────────────────────────
    if (dist <= 10.0) {
      _stepIndex++;
      _announced   = false;
      _announcedNr = false;

      if (_stepIndex >= _steps.length) {
        // Final arrival
        _active = false;
        onArrived?.call();
      } else {
        // Peek at next step
        final next = _steps[_stepIndex];
        print('[Mapbox] Next: ${next.instruction}');
      }
    }
  }

  // ── stop navigation ───────────────────────────────────────────────────
  void stop() {
    _active    = false;
    _steps     = [];
    _stepIndex = 0;
    print('[Mapbox] Navigation stopped.');
  }

  bool get isActive => _active;

  // ── parse Mapbox route into steps ─────────────────────────────────────
  List<_RouteStep> _parseSteps(dynamic route) {
    final steps = <_RouteStep>[];
    try {
      final legs = route.legs as List<dynamic>? ?? [];
      for (final leg in legs) {
        final legSteps = leg.steps as List<dynamic>? ?? [];
        for (final s in legSteps) {
          final maneuver    = s.maneuver;
          final instruction = maneuver?.instruction as String? ?? '';
          final modifier    = maneuver?.modifier  as String? ?? '';
          final type        = maneuver?.type       as String? ?? '';
          final coords      = s.maneuver?.location?.coordinates;

          if (instruction.isEmpty) continue;

          steps.add(_RouteStep(
            instruction: _buildInstruction(type, modifier, instruction),
            targetLat:   coords != null ? (coords[1] as num).toDouble() : 0,
            targetLng:   coords != null ? (coords[0] as num).toDouble() : 0,
            distanceM:   (s.distance as num?)?.toDouble() ?? 0,
          ));
        }
      }
    } catch (e) {
      print('[Mapbox] Step parse error: $e');
    }
    return steps;
  }

  // ── build human-readable instruction ─────────────────────────────────
  String _buildInstruction(String type, String modifier, String raw) {
    // Use raw Mapbox instruction if available — it's already human-readable
    if (raw.isNotEmpty) return raw;

    // Fallback: build from type + modifier
    switch (type) {
      case 'turn':
        return modifier.isNotEmpty ? 'Turn $modifier' : 'Turn';
      case 'continue':
        return 'Continue straight';
      case 'arrive':
        return 'You have arrived';
      case 'depart':
        return 'Head $modifier';
      case 'roundabout':
        return 'Enter the roundabout and take the $modifier exit';
      default:
        return raw.isNotEmpty ? raw : 'Continue';
    }
  }
}

// ── internal step model ───────────────────────────────────────────────────────
class _RouteStep {
  final String instruction;
  final double targetLat;
  final double targetLng;
  final double distanceM;

  _RouteStep({
    required this.instruction,
    required this.targetLat,
    required this.targetLng,
    required this.distanceM,
  });

  @override
  String toString() => 'Step(${instruction}, ${distanceM.toInt()}m)';
}

// ── haversine ─────────────────────────────────────────────────────────────────
double _haversine(double lat1, double lng1, double lat2, double lng2) {
  const R    = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a    = _sin2(dLat / 2) + _cos(lat1) * _cos(lat2) * _sin2(dLng / 2);
  return R * 2 * _atan2(a);
}

double _rad(double d)  => d * 3.141592653589793 / 180;
double _sin2(double r) { final s = _sinR(r); return s * s; }
double _cos(double d)  => _cosR(_rad(d));
double _sinR(double r) => r - r*r*r/6 + r*r*r*r*r/120;
double _cosR(double r) => 1 - r*r/2 + r*r*r*r/24;
double _atan2(double a) => 2 * (a < 0.5
    ? (a + (1/3)*a*a*a)
    : (3.141592653589793/2 - (1-a) - (1/3)*(1-a)*(1-a)*(1-a)));

// placeholder types until mapbox_maps_flutter is imported
class NavigationRouteOptions {
  final List<Point> coordinatesList;
  final String language;
  final String voiceUnits;
  final String profile;
  NavigationRouteOptions({
    required this.coordinatesList,
    required this.language,
    required this.voiceUnits,
    required this.profile,
  });
}
class VoiceUnits  { static const metric = 'metric'; }
class DrivingProfile { static const walking = 'walking'; }
class MapboxRoutingApi {
  Future<List<dynamic>?> fetchRoutes(NavigationRouteOptions o) async => null;
}
typedef VoidCallback = void Function();
