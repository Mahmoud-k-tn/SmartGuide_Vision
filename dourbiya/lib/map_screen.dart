import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
// Mapbox also exports a `Size` class; hide it so the GO BACK button below
// resolves Flutter's Size.fromHeight.
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'map/navigation/navigation_manager.dart';
import 'services/stt_service.dart';
import 'services/tts_service.dart';

/// Full SmartGuide Mapbox navigation screen, ported into dourbiya to replace
/// the old Google Maps screen. Pushed from the "OPEN MAP" button on HomeScreen.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.sttService,
    required this.ttsService,
    required this.micActiveNotifier,
  });

  final SttService sttService;
  final TtsService ttsService;
  final ValueNotifier<bool> micActiveNotifier;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final NavigationManager _nav = NavigationManager();

  bool   _started     = false;
  bool   _piConnected = false;
  String _waypoint    = '';
  String _distance    = '';
  String _lastAlert   = '';
  double _userLat     = 0;
  double _userLng     = 0;
  double _heading     = 0;

  MapboxMap?               _mapboxMap;
  CircleAnnotationManager? _landmarkCircleMgr;
  PointAnnotationManager?  _pointAnnotMgr;

  // whether the user-dot layer has been added to the map style
  bool _userLayerReady = false;

  bool _micOn = false;
  bool _micBusy = false;

  @override
  void initState() {
    super.initState();
    _micOn = widget.micActiveNotifier.value;
    widget.micActiveNotifier.addListener(_onMicNotifierChanged);
    _init();
  }

  void _onMicNotifierChanged() {
    final v = widget.micActiveNotifier.value;
    if (mounted && v != _micOn) {
      setState(() => _micOn = v);
    }
  }

  Future<void> _toggleMapMic() async {
    if (_micBusy) return;
    _micBusy = true;
    try {
      final newState = !_micOn;
      if (newState) {
        await widget.sttService.startListening();
        widget.micActiveNotifier.value = true;
        await widget.ttsService.speak('Microphone on.');
      } else {
        await widget.sttService.stopListening();
        widget.micActiveNotifier.value = false;
        await widget.ttsService.speak('Microphone off.');
      }
    } finally {
      _micBusy = false;
    }
  }

  Future<void> _init() async {
    _nav.onWaypointChanged = (n, d) {
      if (mounted) setState(() { _waypoint = n; _distance = d; });
    };
    _nav.onAlert = (a) { if (mounted) setState(() => _lastAlert = a); };

    _nav.onLocationUpdate = (lat, lng) {
      if (!mounted) return;
      setState(() { _userLat = lat; _userLng = lng; });
      _updateUserDot(lat, lng, _heading);
      _moveCameraTo(lat, lng);
    };

    _nav.onHeadingUpdate = (heading) {
      if (!mounted) return;
      setState(() => _heading = heading);
      // rotate the dot in-place without waiting for a GPS fix
      if (_userLat != 0) _updateUserDot(_userLat, _userLng, heading);
    };

    _nav.pi.onConnected    = () { if (mounted) setState(() => _piConnected = true); };
    _nav.pi.onDisconnected = () { if (mounted) setState(() => _piConnected = false); };

    await _nav.init();
    if (mounted) setState(() {
      _started = true;
    });
    _nav.startCircuit();

    if (_mapboxMap != null) await _drawAll(_mapboxMap!);

    if (mounted) {
      await widget.ttsService.speak(
        'Voice commands are off. Tap the microphone button at the top to enable them.',
      );
    }
  }

  // ── camera ────────────────────────────────────────────────────────────────
  void _moveCameraTo(double lat, double lng) {
    _mapboxMap?.easeTo(
      CameraOptions(
        center:  Point(coordinates: Position(lng, lat)),
        zoom:    18.0,
        bearing: _heading,   // rotate map to match compass — "up" = forward
      ),
      MapAnimationOptions(duration: 200),
    );
  }

  // ── user dot via GeoJSON source + symbol layer ────────────────────────────
  Future<void> _setupUserDotLayer(MapboxMap map) async {
    const emptyGeoJson = '{"type":"FeatureCollection","features":[]}';

    try { await map.style.removeStyleLayer('user-arrow-layer');  } catch (_) {}
    try { await map.style.removeStyleLayer('user-circle-layer'); } catch (_) {}
    try { await map.style.removeStyleSource('user-dot-source');  } catch (_) {}

    await map.style.addSource(GeoJsonSource(
      id:   'user-dot-source',
      data: emptyGeoJson,
    ));

    // green circle - always visible, no image dependency
    await map.style.addLayer(CircleLayer(
      id:                'user-circle-layer',
      sourceId:          'user-dot-source',
      circleRadius:      10.0,
      circleColor:       0xFF00FF88,
      circleOpacity:     1.0,
      circleStrokeWidth: 2.5,
      circleStrokeColor: 0xFFFFFFFF,
    ));

    // arrow rotated by bearing property
    try {
      final imageBytes = await _buildArrowImage(size: 40);
      try { await map.style.removeStyleImage('user-arrow'); } catch (_) {}
      await map.style.addStyleImage(
        'user-arrow', 1.0,
        // embedded PNG is 40x40 — dimensions must match the decoded byte size
        MbxImage(width: 40, height: 40, data: imageBytes),
        false, [], [], null,
      );
      await map.style.addLayer(SymbolLayer(
        id:                    'user-arrow-layer',
        sourceId:              'user-dot-source',
        iconImage:             'user-arrow',
        iconSize:              0.8,
        iconAllowOverlap:      true,
        iconIgnorePlacement:   true,
        iconRotate:            0,
        iconRotationAlignment: IconRotationAlignment.MAP,
      ));
      await map.style.setStyleLayerProperty(
        'user-arrow-layer', 'icon-rotate', '["get","bearing"]',
      );
      print('[Map] Arrow layer ready');
    } catch (e) {
      print('[Map] Arrow skipped, circle showing: $e');
    }

    _userLayerReady = true;
    print('[Map] User dot layer ready');
  }

  // push updated position + bearing into the GeoJSON source
  Future<void> _updateUserDot(double lat, double lng, double heading) async {
    if (_mapboxMap == null || !_userLayerReady) return;
    final geojson = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{"bearing":${heading.toStringAsFixed(1)}}}]}';
    try {
      await _mapboxMap!.style.setStyleSourceProperty(
        'user-dot-source', 'data', geojson,
      );
    } catch (_) {}
  }


  // ── map created ───────────────────────────────────────────────────────────
  void _onMapCreated(MapboxMap map) async {
    _mapboxMap = map;

    final waypoints = _nav.circuit.waypoints;
    if (waypoints.isNotEmpty) {
      await map.setCamera(CameraOptions(
        center: Point(coordinates: Position(waypoints.first.lng, waypoints.first.lat)),
        zoom:   17.0,
      ));
    }

    await Future.delayed(const Duration(milliseconds: 1500));
    if (_nav.circuit.waypoints.isNotEmpty) {
      _landmarkCircleMgr = null;
      _pointAnnotMgr     = null;
      await _drawAll(map);
    }
  }

  void _onStyleLoaded(StyleLoadedEventData data) async {
    if (_mapboxMap == null || _nav.circuit.waypoints.isEmpty) return;
    _userLayerReady    = false;
    _landmarkCircleMgr = null;
    _pointAnnotMgr     = null;
    await _drawAll(_mapboxMap!);
  }

  Future<void> _drawAll(MapboxMap map) async {
    await _drawCircuitLine(map);
    await _drawLandmarkMarkers(map);
    await _setupUserDotLayer(map);  // always set up after style is ready
  }

  Future<void> _drawCircuitLine(MapboxMap map) async {
    final waypoints = _nav.circuit.waypoints;
    if (waypoints.isEmpty) return;

    final coordsList = waypoints.map((w) => '[${w.lng},${w.lat}]').join(',');
    final geojson    = '{"type":"FeatureCollection","features":['
        '{"type":"Feature","geometry":{"type":"LineString","coordinates":[$coordsList]},'
        '"properties":{}}]}';

    try { await map.style.removeStyleLayer('circuit-line'); }   catch (_) {}
    try { await map.style.removeStyleSource('circuit-source'); } catch (_) {}

    try {
      await map.style.addSource(GeoJsonSource(id: 'circuit-source', data: geojson));
      await map.style.addLayer(LineLayer(
        id:          'circuit-line',
        sourceId:    'circuit-source',
        lineColor:   0xFF2196F3,
        lineWidth:   3.0,
      ));
    } catch (e) { print('[Map] Circuit error: $e'); }
  }

  Future<void> _drawLandmarkMarkers(MapboxMap map) async {
    final landmarks = _nav.circuit.landmarks;
    if (landmarks.isEmpty) return;

    _landmarkCircleMgr = await map.annotations.createCircleAnnotationManager();
    _pointAnnotMgr     = await map.annotations.createPointAnnotationManager();

    for (final lm in landmarks) {
      final point = Point(coordinates: Position(lm.lng, lm.lat));
      await _landmarkCircleMgr!.create(CircleAnnotationOptions(
        geometry:          point,
        circleRadius:      8.0,
        circleColor:       0xFFFF3333,
        circleOpacity:     0.9,
        circleStrokeWidth: 2.0,
        circleStrokeColor: 0xFFFFFFFF,
      ));
      await _pointAnnotMgr!.create(PointAnnotationOptions(
        geometry:   point,
        textField:  lm.name.replaceAll('_', ' '),
        textSize:   13.0,
        textOffset: [0.0, 2.5],
        textColor:  0xFFFFFFFF,
      ));
    }
  }

  @override
  void dispose() {
    widget.micActiveNotifier.removeListener(_onMicNotifierChanged);
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [

          // ── top bar: full-width mic toggle ──────────────────────────
          Semantics(
            button: true,
            label: _micOn ? 'Microphone on, tap to turn off' : 'Microphone off, tap to turn on',
            child: Material(
              color: _micOn ? Colors.yellow : Colors.black,
              child: InkWell(
                onTap: _toggleMapMic,
                child: Container(
                  height: 72,
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Colors.yellow, width: 2),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _micOn ? Icons.mic : Icons.mic_off,
                        color: _micOn ? Colors.black : Colors.yellow,
                        size: 36,
                      ),
                      const SizedBox(width: 14),
                      Text(
                        _micOn ? 'MIC ON' : 'MIC OFF',
                        style: TextStyle(
                          color: _micOn ? Colors.black : Colors.yellow,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── map ───────────────────────────────────────────────────────
          Expanded(
            child: Stack(children: [
              MapWidget(
                key:                  const ValueKey('mapbox-map'),
                styleUri:             MapboxStyles.DARK,
                onMapCreated:         _onMapCreated,
                onStyleLoadedListener: _onStyleLoaded,
              ),

              // ── Raspberry Pi connection indicator ─────────────────
              Positioned(
                top: 8, left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _piConnected ? Icons.wifi : Icons.wifi_off,
                        color: _piConnected ? Colors.greenAccent : Colors.redAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _piConnected ? 'Pi' : 'Pi off',
                        style: TextStyle(
                          color: _piConnected ? Colors.greenAccent : Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── GPS coords + heading ──────────────────────────────
              if (_userLat != 0)
                Positioned(
                  top: 8, right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${_userLat.toStringAsFixed(5)}\n'
                      '${_userLng.toStringAsFixed(5)}\n'
                      '↑ ${_heading.toInt()}°',
                      style: const TextStyle(color: Colors.white54, fontSize: 10),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),

              // ── bottom cards ──────────────────────────────────────
              if (_started)
                Positioned(
                  bottom: 16, left: 16, right: 16,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [

                    if (_lastAlert.isNotEmpty && _lastAlert.startsWith('Landmark'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _card(
                          icon:     Icons.place,
                          color:    Colors.redAccent,
                          title:    'LANDMARK',
                          value:    _lastAlert.replaceFirst('Landmark: ', ''),
                          subtitle: 'You have arrived',
                        ),
                      ),

                    _card(
                      icon:     Icons.navigation,
                      color:    Colors.blueAccent,
                      title:    'CURRENT TARGET',
                      value:    _waypoint.isEmpty ? 'Calculating...' : _waypoint,
                      subtitle: _distance,
                    ),
                  ]),
                ),
            ]),
          ),

          // ── accessible GO BACK button (matches dourbiya style) ─────────
          SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.yellow,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(96),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: Colors.black, width: 4),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                child: const Text('GO BACK'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _card({
    required IconData icon,
    required Color    color,
    required String   title,
    required String   value,
    required String   subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color:        const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border:       Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 28),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(
                color: color, fontSize: 10, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(
                color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, style: const TextStyle(
                  color: Colors.white54, fontSize: 12)),
            ],
          ],
        )),
      ]),
    );
  }
}

// ── arrow image: pre-built PNG, no Canvas/dart:ui needed ────────────────────
// 40x40 RGBA PNG of a green directional arrow pointing up.
// Mapbox rotates it via icon-rotate using the "bearing" feature property.
const String _kArrowPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAA0klEQVR42uXYUQ6EMAgEUA/m'
    'AfdA3A+/12w2HZgBrCZ8mr5MraEcx+se/9gcCFpjYSXQ34udQAmhGMwhKBm3kpTDiRbjvAYZ'
    '+85Q4DdUmNwdhyKBJOOnNAMEkDycYKu56QlS5OOIKWrSI6aow5FS5PxWWMj9gZ6oHYHYCXZC'
    'BU7yRGBgi1cXzyL3BDoZ6ExgZMEM8i/QmoG20jCwkoi8u9RuWRPQkKb1bCio5bcWnPjiVIDr'
    '2er05d3mJFeHlA2QjAYTj+AGzQcfMWF9zIy6eMp/Ad01EKAGFlu/AAAAAElFTkSuQmCC';

Future<Uint8List> _buildArrowImage({int size = 64}) async {
  return base64Decode(_kArrowPngBase64);
}
