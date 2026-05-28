import 'dart:async';
import 'dart:convert';

import 'package:vosk_flutter/vosk_flutter.dart';

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

  bool _initialized = false;
  bool _isListening = false;
  bool _isPaused = false;

  Future<void> initialize({
    required String modelAssetPath,
    int sampleRate = 16000,
  }) async {
    if (_initialized) return;

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

    _initialized = true;
  }

  Future<void> startListening() async {
    if (!_initialized || _speechService == null) return;
    await _speechService!.start();
    _isListening = true;
    _isPaused = false;
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

  Future<void> dispose() async {
    await _partialSub?.cancel();
    await _resultSub?.cancel();

    await _speechService?.stop();
    await _recognizer?.dispose();
    _model?.dispose();

    _isListening = false;
    _isPaused = false;

    await _partialController.close();
    await _resultController.close();
  }
}
