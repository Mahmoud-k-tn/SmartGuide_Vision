import 'dart:async';
import 'dart:convert';

import 'package:vosk_flutter/vosk_flutter.dart';

/// Offline speech-to-text wrapper around Vosk.
///
/// Supports hot-swapping the underlying model so the app can switch between
/// EN / FR / AR without restart. Switching is asynchronous and is a no-op if
/// the requested model asset is the same as the one currently loaded.
class SttService {
  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  final StreamController<String> _partialController = StreamController<String>.broadcast();
  final StreamController<String> _resultController = StreamController<String>.broadcast();

  Stream<String> get partialStream => _partialController.stream;
  Stream<String> get resultStream => _resultController.stream;

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;

  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _resultSub;

  String? _loadedAssetPath;

  bool _initialized = false;
  bool _isListening = false;
  bool _isPaused = false;

  bool get isReady => _initialized && _speechService != null;
  bool get isListening => _isListening;
  String? get loadedAssetPath => _loadedAssetPath;

  /// Initialise (or re-initialise) the engine with the given Vosk model asset.
  /// Safe to call repeatedly -- if [modelAssetPath] matches the loaded model
  /// it returns immediately.
  Future<void> initialize({
    required String modelAssetPath,
    int sampleRate = 16000,
  }) async {
    if (_initialized && _loadedAssetPath == modelAssetPath) return;

    if (_initialized) {
      await _disposeEngine();
    }

    final modelPath = await ModelLoader().loadFromAssets(modelAssetPath);

    _model = await _vosk.createModel(modelPath);
    _recognizer = await _vosk.createRecognizer(
      model: _model!,
      sampleRate: sampleRate,
    );

    _speechService = await _vosk.initSpeechService(_recognizer!);

    _partialSub = _speechService!.onPartial().listen((jsonString) {
      final partial = _extractField(jsonString, 'partial');
      if (partial.isNotEmpty) _partialController.add(partial);
    });

    _resultSub = _speechService!.onResult().listen((jsonString) {
      final text = _extractField(jsonString, 'text');
      if (text.isNotEmpty) _resultController.add(text);
    });

    _loadedAssetPath = modelAssetPath;
    _initialized = true;
  }

  /// Replace the currently-loaded model with a new one (used when the user
  /// changes language). Returns true on success, false if the new model
  /// failed to load (e.g. asset missing for Arabic).
  Future<bool> switchModel(String newAssetPath, {int sampleRate = 16000}) async {
    if (_loadedAssetPath == newAssetPath) return true;
    final wasListening = _isListening;
    try {
      if (wasListening) await stopListening();
      await initialize(modelAssetPath: newAssetPath, sampleRate: sampleRate);
      if (wasListening) await startListening();
      return true;
    } catch (_) {
      _initialized = false;
      _loadedAssetPath = null;
      return false;
    }
  }

  Future<void> startListening() async {
    if (!_initialized || _speechService == null) return;
    // Retry: on Android the AudioRecord from a previous session may still
    // be releasing when the user taps quickly. A short backoff fixes this.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _speechService!.start();
        _isListening = true;
        _isPaused = false;
        return;
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }
    throw StateError('Could not start speech listening: $lastError');
  }

  Future<void> stopListening() async {
    if (!_initialized || _speechService == null) return;
    await _speechService!.stop();
    _isListening = false;
    _isPaused = false;
  }

  Future<void> pauseListening() async {
    if (!_initialized || _speechService == null || !_isListening || _isPaused) return;
    await _speechService!.setPause(paused: true);
    _isPaused = true;
  }

  Future<void> resumeListening() async {
    if (!_initialized || _speechService == null || !_isListening || !_isPaused) return;
    await _speechService!.setPause(paused: false);
    _isPaused = false;
  }

  String _extractField(String jsonString, String key) {
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is Map<String, dynamic>) {
        return (decoded[key] ?? '').toString().trim();
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  Future<void> _disposeEngine() async {
    await _partialSub?.cancel();
    await _resultSub?.cancel();
    _partialSub = null;
    _resultSub = null;

    try { await _speechService?.stop(); } catch (_) {}
    try { await _speechService?.dispose(); } catch (_) {}
    try { await _recognizer?.dispose(); } catch (_) {}
    try { _model?.dispose(); } catch (_) {}

    _speechService = null;
    _recognizer = null;
    _model = null;

    _isListening = false;
    _isPaused = false;
    _initialized = false;
    _loadedAssetPath = null;
  }

  Future<void> dispose() async {
    await _disposeEngine();
    await _partialController.close();
    await _resultController.close();
  }
}
