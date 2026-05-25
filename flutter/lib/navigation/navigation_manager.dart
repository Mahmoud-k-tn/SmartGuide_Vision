// lib/navigation/navigation_manager.dart

import 'dart:async';
import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:flutter_compass/flutter_compass.dart';
import '../core/pi_connection.dart';
import '../core/audio_manager.dart';
import '../navigation/circuit_manager.dart';
import '../navigation/proximity_alert.dart';

// ── GPS filter thresholds ─────────────────────────────────────────────────────
const double _MAX_ACCURACY_M  = 50.0;  // reject fixes worse than 50m
const double _MAX_SPEED_MS    =  8.0;  // reject fixes implying > 8 m/s walking
const double _MIN_MOVE_M      =  1.5;  // ignore jitter smaller than 1.5m

// ── TTS throttle ─────────────────────────────────────────────────────────────
const double _SPEAK_DIST_CHANGE_M = 12.0; // re-speak when distance drops by 12m
const int    _SPEAK_COOLDOWN_SEC  =  6;   // never speak more often than every 6s
const double _HEADING_AGREE_DEG   = 40.0; // if user faces within 40° of target,
                                           // suppress direction word — just say distance

class NavigationManager {
  final CircuitManager _circuit = CircuitManager();
  final AudioManager   _audio   = AudioManager();
  late  ProximityAlert _proximity;
  final PiConnection   _pi      = PiConnection();

  // expose for UI
  PiConnection   get pi      => _pi;
  CircuitManager get circuit => _circuit;

  // UI callbacks
  void Function(String status)?            onStatusChanged;
  void Function(String name, String dist)? onWaypointChanged;
  void Function(String alert)?             onAlert;
  void Function(double lat, double lng)?   onLocationUpdate;
  void Function(double heading)?           onHeadingUpdate;

  StreamSubscription<Position>?     _gpsSub;
  StreamSubscription<CompassEvent>? _compassSub;
  bool   _visualLockActive = false;
  bool   _navigating       = false;

  // raw last accepted fix
  double    _lastRawLat  = 0;
  double    _lastRawLng  = 0;
  DateTime? _lastFixTime;
  int       _fixCount    = 0;

  // smoothed position used for navigation + map
  double _lastLat = 0;
  double _lastLng = 0;

  // compass heading (degrees, 0 = north)
  double _currentHeading = 0;

  // TTS state
  String    _lastSpokenDir   = '';
  double    _lastSpokenDist  = 9999;
  DateTime? _lastSpokenTime;
  Timer?    _repeatTimer;

  // ── init ─────────────────────────────────────────────────────────────────
  Future<void> init() async {
    await _audio.init();
    _proximity = ProximityAlert(_audio);

    try {
      await _circuit.load(
        circuitPath:   'assets/circuit.geojson',
        landmarksPath: 'assets/landmarks.geojson',
      );
      print('[Nav] Loaded ${_circuit.waypoints.length} waypoints');
      if (_circuit.waypoints.isEmpty) {
        onStatusChanged?.call('ERROR: circuit.geojson is empty or missing');
      }
    } catch (e) {
      print('[Nav] Circuit load error: $e');
      onStatusChanged?.call('ERROR loading circuit: $e');
    }

    _pi.onMessage      = _onPiMessage;
    _pi.onConnected    = () {
      print('[Nav] Pi connected.');
      onStatusChanged?.call('Pi connected -- tap to start');
    };
    _pi.onDisconnected = () => print('[Nav] Pi disconnected.');
    _pi.connect();

    await _ensureLocationPermission();
    _startCompassStream();
    print('[Nav] Ready -- ${_circuit.waypoints.length} waypoints loaded.');
  }

  // ── compass ───────────────────────────────────────────────────────────────
  void _startCompassStream() {
    final stream = FlutterCompass.events;
    if (stream == null) {
      print('[Nav] Compass not available on this device');
      return;
    }
    _compassSub = stream.listen((CompassEvent event) {
      if (event.heading != null) {
        _currentHeading = event.heading!;
        onHeadingUpdate?.call(_currentHeading);
      }
    });
    print('[Nav] Compass stream started');
  }

  // ── start navigation ──────────────────────────────────────────────────────
  Future<void> startCircuit() async {
    if (_circuit.waypoints.isEmpty) {
      await _audio.speak('No waypoints found. Check circuit file.');
      onStatusChanged?.call('No waypoints found');
      return;
    }
    _navigating = true;
    _startGpsStream();
    _startRepeatTimer();

    final wp = _circuit.current;
    await _audio.speak('Circuit started. Head to ${wp?.name}.');
    onStatusChanged?.call('Navigating');
    onWaypointChanged?.call(wp?.name ?? '', 'Calculating...');
    print('[Nav] Circuit started. First stop: ${wp?.name}');
  }

  void _startGpsStream() {
    const settings = LocationSettings(
      accuracy:       LocationAccuracy.bestForNavigation,
      distanceFilter: 1,
    );
    _gpsSub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onLocation);
  }

  // ── GPS handler ───────────────────────────────────────────────────────────
  Future<void> _onLocation(Position pos) async {
    print('[GPS] acc=${pos.accuracy.toStringAsFixed(1)}m '
          'speed=${pos.speed.toStringAsFixed(1)}m/s '
          'lat=${pos.latitude} lng=${pos.longitude}');

    // 1. Accuracy gate (bypass first 5 fixes for cold-start)
    _fixCount++;
    if (_fixCount > 5 && pos.accuracy > _MAX_ACCURACY_M) {
      print('[Nav] GPS rejected: accuracy ${pos.accuracy.toStringAsFixed(1)}m');
      return;
    }

    // 2. Speed gate (teleport guard)
    if (_lastRawLat != 0 && _lastFixTime != null) {
      final elapsed = DateTime.now().difference(_lastFixTime!).inMilliseconds / 1000.0;
      if (elapsed > 0) {
        final jumped       = haversine(_lastRawLat, _lastRawLng, pos.latitude, pos.longitude);
        final impliedSpeed = jumped / elapsed;
        if (impliedSpeed > _MAX_SPEED_MS) {
          print('[Nav] GPS rejected: implied speed ${impliedSpeed.toStringAsFixed(1)} m/s');
          return;
        }
      }
    }

    // 3. Minimum movement gate (standing-still jitter)
    if (_lastRawLat != 0) {
      final moved = haversine(_lastRawLat, _lastRawLng, pos.latitude, pos.longitude);
      if (moved < _MIN_MOVE_M) {
        onLocationUpdate?.call(_lastLat, _lastLng);
        return;
      }
    }

    // 4. Accept fix
    _lastRawLat  = pos.latitude;
    _lastRawLng  = pos.longitude;
    _lastFixTime = DateTime.now();

    // 5. Accept position directly — GPS filter already handles jitter/teleports
    _lastLat = pos.latitude;
    _lastLng = pos.longitude;

    // 6. Update map
    onLocationUpdate?.call(_lastLat, _lastLng);

    if (!_navigating || _visualLockActive) return;

    // 7. Send to Pi
    _pi.sendGps(_lastLat, _lastLng);

    // 8. Landmark proximity
    final nearLandmark = _circuit.checkLandmarkProximity(_lastLat, _lastLng);
    if (nearLandmark != null) {
      await _audio.speak('You are at $nearLandmark');
      onAlert?.call('Landmark: $nearLandmark');
    }

    await _proximity.checkGps(_lastLat, _lastLng, _circuit);

    if (_circuit.isComplete) { await _onCircuitComplete(); return; }

    final dist = _circuit.distanceToCurrent(_lastLat, _lastLng);
    final name = _circuit.current?.name ?? '';

    // 9. Breadcrumb advance
    if (dist < 4.0) {
      print('[Nav] Reached $name, advancing.');
      _circuit.advance();
      if (_circuit.isComplete) { await _onCircuitComplete(); return; }
      final nextName = _circuit.current?.name ?? '';
      await _audio.speak('Reached $name. Now head to $nextName.');
      onWaypointChanged?.call(nextName, 'Calculating...');
      _lastSpokenDir  = '';
      _lastSpokenDist = 9999;
      _lastSpokenTime = null;
      return;
    }

    final bearingToTarget = _circuit.bearingToCurrent(_lastLat, _lastLng);
    final dir             = bearingToDirection(bearingToTarget);
    onWaypointChanged?.call(name, '${dist.toInt()}m -- $dir');
    await _speakDirectionIfNeeded(name, dist, dir, bearingToTarget);
  }

  // ── smart TTS ─────────────────────────────────────────────────────────────
  Future<void> _speakDirectionIfNeeded(
    String name, double dist, String dir, double bearingToTarget,
  ) async {
    final now = DateTime.now();

    // cooldown check first — never speak more often than every 6 seconds
    final cooledDown = _lastSpokenTime == null ||
        now.difference(_lastSpokenTime!).inSeconds >= _SPEAK_COOLDOWN_SEC;
    if (!cooledDown) return;

    final distChanged = (_lastSpokenDist - dist) > _SPEAK_DIST_CHANGE_M;
    final dirChanged  = dir != _lastSpokenDir;

    if (!distChanged && !dirChanged) return;

    // ── heading agreement check ───────────────────────────────────────────
    // If the user is already roughly facing the target, don't repeat the
    // direction word — just say the distance. This stops the "turn left"
    // repetition after the user has already turned.
    final headingDiff = _angleDiff(_currentHeading, bearingToTarget);
    final alreadyFacing = headingDiff < _HEADING_AGREE_DEG;

    String phrase;
    if (alreadyFacing) {
      // user is facing the right way — distance update only
      phrase = '${dist.toInt()} metres to $name';
    } else {
      // user still needs to turn
      phrase = 'Head $dir, ${dist.toInt()} metres to $name';
    }

    _lastSpokenDir  = dir;
    _lastSpokenDist = dist;
    _lastSpokenTime = now;
    _resetRepeatTimer();

    await _audio.speak(phrase, priority: AudioPriority.p2Navigation);
  }

  // ── repeat timer ──────────────────────────────────────────────────────────
  void _startRepeatTimer() {
    _repeatTimer?.cancel();
    _repeatTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_navigating || _visualLockActive) return;
      final wp = _circuit.current;
      if (wp == null || (_lastLat == 0 && _lastLng == 0)) return;

      final dist            = _circuit.distanceToCurrent(_lastLat, _lastLng);
      final bearingToTarget = _circuit.bearingToCurrent(_lastLat, _lastLng);
      final dir             = bearingToDirection(bearingToTarget);
      final headingDiff     = _angleDiff(_currentHeading, bearingToTarget);
      final alreadyFacing   = headingDiff < _HEADING_AGREE_DEG;

      // same heading-agreement logic as above
      final phrase = alreadyFacing
          ? '${dist.toInt()} metres to ${wp.name}'
          : 'Head $dir, ${dist.toInt()} metres to ${wp.name}';

      _lastSpokenDir  = dir;
      _lastSpokenDist = dist;
      _lastSpokenTime = DateTime.now();

      await _audio.speak(phrase, priority: AudioPriority.p2Navigation);
    });
  }

  void _resetRepeatTimer() {
    _repeatTimer?.cancel();
    _startRepeatTimer();
  }

  // ── Pi messages ───────────────────────────────────────────────────────────
  Future<void> _onPiMessage(Map<String, dynamic> msg) async {
    final alert = await _proximity.onPiMessage(msg);

    if (alert is ObstacleDetected) {
      onAlert?.call('Obstacle ${alert.direction} -- ${alert.distanceM.toStringAsFixed(1)}m');
    }
    if (alert is MonumentVisible && !_visualLockActive) {
      _visualLockActive = true;
      onStatusChanged?.call('Visual Lock -- Pi guiding to entrance');
    }
    if (alert is MonumentEntrance) {
      _visualLockActive = false;
      _navigating       = false;
      await _gpsSub?.cancel();
      onStatusChanged?.call('Entering ${alert.name}');
      _pi.send({'type': 'start_indoor', 'monument': alert.name});
    }
  }

  Future<void> _onCircuitComplete() async {
    _navigating = false;
    _repeatTimer?.cancel();
    await _gpsSub?.cancel();
    await _audio.speak('You have completed the full circuit. Well done.');
    onStatusChanged?.call('Circuit complete');
  }

  Future<void> _ensureLocationPermission() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      print('[Nav] Location permission permanently denied.');
    }
  }

  Future<void> dispose() async {
    _repeatTimer?.cancel();
    await _gpsSub?.cancel();
    await _compassSub?.cancel();
    await _audio.dispose();
    await _pi.dispose();
  }
}

// ── helpers ───────────────────────────────────────────────────────────────────

String bearingToDirection(double deg) {
  final d = deg % 360;
  if (d < 22.5  || d >= 337.5) return 'straight ahead';
  if (d < 67.5)                return 'slightly right';
  if (d < 112.5)               return 'right';
  if (d < 157.5)               return 'sharp right';
  if (d < 202.5)               return 'behind you';
  if (d < 247.5)               return 'sharp left';
  if (d < 292.5)               return 'left';
  return 'slightly left';
}

// smallest angle between two compass bearings (0–180)
double _angleDiff(double a, double b) {
  final diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}