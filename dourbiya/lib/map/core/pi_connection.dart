// lib/core/pi_connection.dart
// WebSocket client for Pi ↔ Phone communication.
// Replaces PiConnectionManager.kt — pure Dart.

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'config.dart';

typedef PiMessageCallback = void Function(Map<String, dynamic> message);

class PiConnection {
  static const String _piHost    = Config.PI_HOST; // 192.168.4.1 — matches dourbiya
  static const int    _piPort    = Config.PI_PORT;
  static const Duration _reconnectDelay = Duration(seconds: 3);

  WebSocketChannel?   _channel;
  StreamSubscription? _sub;
  bool _disposed   = false;
  bool _connecting = false;

  PiMessageCallback? onMessage;
  VoidCallback?      onConnected;
  VoidCallback?      onDisconnected;

  // ── connect ───────────────────────────────────────────────────────────
  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;

    try {
      final uri = Uri.parse('ws://$_piHost:$_piPort');
      _channel  = WebSocketChannel.connect(uri);

      await _channel!.ready;
      _connecting = false;

      print('[Pi] Connected to $uri');
      onConnected?.call();

      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone:  _onDone,
      );

    } catch (e) {
      _connecting = false;
      print('[Pi] Connection failed: $e — retrying in ${_reconnectDelay.inSeconds}s');
      _scheduleReconnect();
    }
  }

  // ── send JSON to Pi ───────────────────────────────────────────────────
  void send(Map<String, dynamic> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (e) {
      print('[Pi] Send failed: $e');
    }
  }

  // ── send GPS position to Pi (for Visual Lock distance calc) ──────────
  void sendGps(double lat, double lng) {
    send({'type': 'gps_update', 'lat': lat, 'lng': lng});
  }

  // ── internals ─────────────────────────────────────────────────────────
  void _onData(dynamic raw) {
    try {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      print('[Pi] Received: ${msg['type']}');
      onMessage?.call(msg);
    } catch (e) {
      print('[Pi] Parse error: $e — raw: $raw');
    }
  }

  void _onError(dynamic error) {
    print('[Pi] WebSocket error: $error');
    _scheduleReconnect();
  }

  void _onDone() {
    print('[Pi] Connection closed.');
    onDisconnected?.call();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    Future.delayed(_reconnectDelay, connect);
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    await _channel?.sink.close(ws_status.goingAway);
  }
}

// ignore: camel_case_types
typedef VoidCallback = void Function();
