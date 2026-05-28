import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();

  Future<void> init() async {
    await _flutterTts.setSpeechRate(0.45);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setLanguage('en-US');
  }

  Future<void> speak(String message) async {
    await _flutterTts.stop();
    await _flutterTts.speak(message);
  }

  Future<void> stop() async {
    await _flutterTts.stop();
  }
}
