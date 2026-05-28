import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

class ObstacleWarning {
  ObstacleWarning({
    required this.direction,
    required this.distanceM,
    required this.severity,
  });

  final String direction;
  final double distanceM;
  final String severity;
}

class WebSocketService {
  static const String _url = 'ws://192.168.4.1:8765';

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;

  final StreamController<String> _triggerController = StreamController<String>.broadcast();
  final StreamController<ObstacleWarning> _obstacleController =
      StreamController<ObstacleWarning>.broadcast();

  Stream<String> get triggerStream => _triggerController.stream;
  Stream<ObstacleWarning> get obstacleWarningStream => _obstacleController.stream;

  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_url));
      await _channel!.ready.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw const SocketException('WebSocket handshake timed out');
        },
      );

      _subscription = _channel!.stream.listen(
        _onMessage,
        onError: (error) {
          // Keep app alive even when socket drops.
        },
        onDone: () {
          // Reconnect strategy can be added later.
        },
        cancelOnError: false,
      );
    } catch (_) {
      // Pi not reachable -- app stays usable in standalone mode.
      _channel = null;
    }
  }

  void _onMessage(dynamic rawMessage) {
    final message = rawMessage.toString().trim();
    if (message.isEmpty) return;

    if (message.startsWith('{')) {
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map<String, dynamic>) {
          final type = decoded['type'] as String?;
          if (type == 'obstacle_warning') {
            final distanceRaw = decoded['distance_m'];
            _obstacleController.add(ObstacleWarning(
              direction: (decoded['direction'] as String?) ?? 'ahead',
              distanceM: distanceRaw is num ? distanceRaw.toDouble() : 0.0,
              severity: (decoded['severity'] as String?) ?? 'medium',
            ));
            return;
          }
          if (type == 'obstacle_clear') {
            return;
          }
        }
      } catch (_) {
        // Not JSON we recognize — fall through to trigger handling.
      }
    }

    final triggerId = message.startsWith('trigger:') ? message.substring(8) : message;

    if (triggerId.isNotEmpty) {
      _triggerController.add(triggerId);
    }
  }

  void send(String message) {
    _channel?.sink.add(message);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _channel?.sink.close();
    await _triggerController.close();
    await _obstacleController.close();
  }
}
