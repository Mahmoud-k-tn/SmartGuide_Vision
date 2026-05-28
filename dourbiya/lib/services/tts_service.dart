import 'package:flutter_tts/flutter_tts.dart';

/// Wrapper around flutter_tts that delegates speech to the native OS engine
/// (Google TTS on Android, AVSpeechSynthesizer on iOS). Supports runtime
/// language switching via [setLanguage].
class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  String _currentLanguage = 'en-US';

  String get currentLanguage => _currentLanguage;

  Future<void> init({String initialLanguage = 'en-US'}) async {
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
    await setLanguage(initialLanguage);
  }

  /// Switch the synthesis voice. If the OS does not have a voice installed
  /// for [bcp47Tag], flutter_tts silently falls back to the default voice;
  /// no exception is raised. The method always updates [currentLanguage] so
  /// the caller can detect the desired state.
  Future<void> setLanguage(String bcp47Tag) async {
    _currentLanguage = bcp47Tag;
    try {
      await _flutterTts.setLanguage(bcp47Tag);
    } catch (_) {
      // Language unavailable on this device -- keep going with default voice.
    }
  }

  Future<void> speak(String message) async {
    await _flutterTts.stop();
    await _flutterTts.speak(message);
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }
}
