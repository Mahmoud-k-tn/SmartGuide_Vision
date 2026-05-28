// lib/navigation/proximity_alert.dart
// Fires proximity alerts at 5m from each waypoint.
// Handles Pi WebSocket messages (obstacle / Visual Lock).
// TTS calls are stubbed — replace with Qwen when ready.

import 'package:vibration/vibration.dart';
import '../core/audio_manager.dart';
import '../navigation/circuit_manager.dart';
import '../models/waypoint.dart';

// ── alert types ───────────────────────────────────────────────────────────────
abstract class Alert {}

class ApproachingWaypoint extends Alert {
  final Waypoint waypoint;
  final double   distanceM;
  ApproachingWaypoint(this.waypoint, this.distanceM);
}

class ArrivedAtWaypoint extends Alert {
  final Waypoint waypoint;
  ArrivedAtWaypoint(this.waypoint);
}

class ObstacleDetected extends Alert {
  final String direction;
  final double distanceM;
  ObstacleDetected(this.direction, this.distanceM);
}

class ObstacleClear extends Alert {
  final String direction;
  ObstacleClear(this.direction);
}

class MonumentVisible extends Alert {
  final String name;
  final double distanceM;
  MonumentVisible(this.name, this.distanceM);
}

class MonumentEntrance extends Alert {
  final String name;
  MonumentEntrance(this.name);
}

// ── proximity alert handler ───────────────────────────────────────────────────
class ProximityAlert {
  static const double _proximityM = 5.0;
  static const double _arrivalM   = 2.0;

  final AudioManager _audio;
  int _lastAlertedIndex = -1;

  ProximityAlert(this._audio);

  // ── GPS proximity check — call on every location update ──────────────
  Future<Alert?> checkGps(
    double lat,
    double lng,
    CircuitManager circuit,
  ) async {
    final wp   = circuit.current;
    if (wp == null) return null;
    final dist = circuit.distanceToCurrent(lat, lng);

    if (dist <= _arrivalM && _lastAlertedIndex != wp.index * 2 + 1) {
      _lastAlertedIndex = wp.index * 2 + 1;
      final alert = ArrivedAtWaypoint(wp);
      await _handleAlert(alert);
      circuit.advance();
      return alert;
    }

    if (dist <= _proximityM && _lastAlertedIndex != wp.index * 2) {
      _lastAlertedIndex = wp.index * 2;
      final alert = ApproachingWaypoint(wp, dist);
      await _handleAlert(alert);
      return alert;
    }

    return null;
  }

  // ── Pi message handler — call from PiConnection.onMessage ────────────
  Future<Alert?> onPiMessage(Map<String, dynamic> msg) async {
    final type = msg['type'] as String? ?? '';

    Alert? alert;

    switch (type) {
      case 'obstacle_warning':
        alert = ObstacleDetected(
          msg['direction'] as String? ?? 'ahead',
          (msg['distance_m'] as num?)?.toDouble() ?? 0.0,
        );
        break;

      case 'obstacle_clear':
        alert = ObstacleClear(msg['direction'] as String? ?? 'ahead');
        break;

      case 'visual_lock':
        alert = MonumentVisible(
          msg['monument_name'] as String? ?? 'monument',
          (msg['distance_m'] as num?)?.toDouble() ?? 0.0,
        );
        break;

      case 'entrance_reached':
        alert = MonumentEntrance(msg['monument_name'] as String? ?? 'monument');
        break;

      default:
        print('[ProximityAlert] Unknown Pi message: $type');
    }

    if (alert != null) await _handleAlert(alert);
    return alert;
  }

  // ── central alert dispatcher ──────────────────────────────────────────
  Future<void> _handleAlert(Alert alert) async {
    switch (alert.runtimeType) {

      case ApproachingWaypoint:
        final a = alert as ApproachingWaypoint;
        await _audio.speak(
          'Approaching ${a.waypoint.name} in ${a.distanceM.toInt()} metres',
          priority: AudioPriority.p2Navigation,
        );
        await _vibrate(VibrationPattern.singlePulse);
        break;

      case ArrivedAtWaypoint:
        final a = alert as ArrivedAtWaypoint;
        await _audio.speak(
          'You have arrived at ${a.waypoint.name}',
          priority: AudioPriority.p2Navigation,
        );
        await _vibrate(VibrationPattern.doublePulse);
        break;

      case ObstacleDetected:
        final a = alert as ObstacleDetected;
        await _audio.speak(
          'Obstacle ${a.direction}, ${a.distanceM.toStringAsFixed(1)} metres — slow down',
          priority: AudioPriority.p1Obstacle,
        );
        await _vibrate(VibrationPattern.urgent);
        break;

      case ObstacleClear:
        final a = alert as ObstacleClear;
        await _audio.speak(
          'Path clear ${a.direction}',
          priority: AudioPriority.p2Navigation,
        );
        break;

      case MonumentVisible:
        final a = alert as MonumentVisible;
        await _audio.speak(
          '${a.name} is visible, ${a.distanceM.toInt()} metres ahead — heading to entrance',
          priority: AudioPriority.p2Navigation,
        );
        await _vibrate(VibrationPattern.singlePulse);
        break;

      case MonumentEntrance:
        final a = alert as MonumentEntrance;
        await _audio.speak(
          'You have reached the entrance of ${a.name}',
          priority: AudioPriority.p0Critical,
        );
        await _vibrate(VibrationPattern.doublePulse);
        break;
    }
  }

  // ── vibration patterns ────────────────────────────────────────────────
  Future<void> _vibrate(VibrationPattern pattern) async {
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;

    switch (pattern) {
      case VibrationPattern.singlePulse:
        Vibration.vibrate(duration: 200, amplitude: 128);
        break;
      case VibrationPattern.doublePulse:
        Vibration.vibrate(pattern: [0, 200, 150, 200]);
        break;
      case VibrationPattern.urgent:
        Vibration.vibrate(pattern: [0, 100, 80, 100, 80, 100]);
        break;
    }
  }
}

enum VibrationPattern { singlePulse, doublePulse, urgent }
