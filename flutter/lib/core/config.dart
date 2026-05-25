// lib/core/config.dart
// All app-wide constants — tokens, IPs, thresholds.
// Fill in MAPBOX_TOKEN and QWEN_API_KEY before running.

class Config {
  // ── Mapbox ────────────────────────────────────────────────────────────
  // Get your token from https://account.mapbox.com
  static const String MAPBOX_TOKEN = 'pk.eyJ1Ijoia2Fubm91IiwiYSI6ImNtb2V1NGFqaDBoaXoycnNhMHNkdnA2anoifQ.hOWlm_mtUYu_Fw896APNJw';

  // ── Qwen TTS/STT ─────────────────────────────────────────────────────
  // Fill in when Qwen integration is ready
  static const String QWEN_API_KEY = 'YOUR_QWEN_API_KEY_HERE';
  static const String QWEN_API_URL = 'https://dashscope.aliyuncs.com/api/v1';

  // ── Pi connection ─────────────────────────────────────────────────────
  static const String PI_HOST = '192.168.4.1';
  static const int    PI_PORT = 8765;

  // ── Navigation thresholds ─────────────────────────────────────────────
  static const double PROXIMITY_ALERT_M  = 5.0;   // announce approaching
  static const double ARRIVAL_M          = 2.0;   // announce arrived
  static const double VISUAL_LOCK_M      = 50.0;  // Pi camera takes over

  // ── Mapbox routing ────────────────────────────────────────────────────
  static const double STEP_ANNOUNCE_FAR_M  = 200.0;  // "In 200m, turn left"
  static const double STEP_ANNOUNCE_NEAR_M =  30.0;  // "Turn left"
  static const String ROUTING_PROFILE     = 'walking';
  static const String ROUTING_LANGUAGE    = 'en';
}
