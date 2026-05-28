// lib/core/audio_manager.dart
// TTS stub — all speak() calls print to console.
// Replace body of speak() with Qwen TTS when ready.

import 'package:flutter_tts/flutter_tts.dart';

enum AudioPriority { p0Critical, p1Obstacle, p2Navigation, p3Info, p4Ambient }

class AudioManager {
  final FlutterTts _tts = FlutterTts();
  bool _initialised = false;

  Future<void> init() async {
    await _tts.setLanguage('en-US');   // switch to Arabic Tunisian when Qwen ready
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    _initialised = true;
    print('[AudioManager] Initialised (stub mode — using flutter_tts)');
  }

  /// Speak a message at a given priority.
  /// TODO: replace with Qwen TTS pipeline.
  Future<void> speak(String text, {AudioPriority priority = AudioPriority.p2Navigation}) async {
    // stub — print for now
    print('[TTS P${priority.index}] $text');

    // Uncomment when Qwen is integrated:
    // await QwenClient.synthesise(text, dialect: 'tunisian_arabic');

    // For now use flutter_tts as audible placeholder
    if (_initialised) await _tts.speak(text);
  }

  Future<void> stop() async => _tts.stop();
  Future<void> dispose() async => _tts.stop();
}
