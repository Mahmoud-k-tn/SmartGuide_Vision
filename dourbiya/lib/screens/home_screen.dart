import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../map_screen.dart';
import '../services/database_helper.dart';
import '../services/stt_service.dart';
import '../services/tts_service.dart';
import '../services/websocket_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  final DatabaseHelper _databaseHelper = DatabaseHelper.instance;
  final TtsService _ttsService = TtsService();
  final SttService _sttService = SttService();
  final WebSocketService _webSocketService = WebSocketService();

  StreamSubscription<String>? _webSocketSub;
  StreamSubscription<ObstacleWarning>? _obstacleSub;
  StreamSubscription<String>? _sttResultSub;
  StreamSubscription<String>? _sttPartialSub;

  late final AnimationController _pulseController;
  late final ValueNotifier<bool> _micActiveNotifier;

  bool _isListening = false;
  bool _isSpeaking = false;
  bool _isOpeningMap = false;
  bool _sttReady = false;
  bool _canVibrate = false;
  String _status = 'Initializing offline services...';
  String _lastTrigger = '-';
  String _lastHeard = '-';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _micActiveNotifier = ValueNotifier<bool>(false);
    _micActiveNotifier.addListener(_onMicNotifierChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _databaseHelper.initialize();
      await _ttsService.init();

      _canVibrate = await Vibration.hasVibrator();

      final micReady = await _ensureMicrophonePermission();
      if (!micReady) {
        _setStatus('Microphone permission is required for speech recognition.');
        await _speakSafely('Please allow microphone permission and try again.');
        return;
      }

      await _sttService.initialize(
        modelAssetPath: 'assets/models/vosk-model-small-en-us-0.15.zip',
        sampleRate: 16000,
      );
      _sttReady = true;

      await _webSocketService.connect();

      _webSocketSub = _webSocketService.triggerStream.listen((triggerId) async {
        await _handleTriggerId(triggerId, source: 'Raspberry Pi');
      });

      _obstacleSub = _webSocketService.obstacleWarningStream.listen((warning) async {
        await _handleObstacleWarning(warning);
      });

      _sttResultSub = _sttService.resultStream.listen((recognizedText) async {
        await _handleVoiceCommand(recognizedText);
      });

      _sttPartialSub = _sttService.partialStream.listen((partialText) {
        final normalized = partialText.trim();
        if (normalized.isEmpty) return;
        _setStatus('Heard: $normalized');
      });

      await _speakSafely('Dourbiya is ready in offline mode.');
      _setStatus('Ready. Tap anywhere to listen for voice command.');
    } catch (error) {
      _setStatus('Initialization failed: $error');
    }
  }

  Future<bool> _ensureMicrophonePermission() async {
    var micStatus = await Permission.microphone.status;
    if (micStatus.isGranted) return true;

    micStatus = await Permission.microphone.request();
    return micStatus.isGranted;
  }

  void _onMicNotifierChanged() {
    final v = _micActiveNotifier.value;
    if (v != _isListening && mounted) {
      setState(() => _isListening = v);
    }
  }

  void _setListening(bool on) {
    if (mounted) setState(() => _isListening = on);
    _micActiveNotifier.value = on;
  }

  Future<void> _haptic(List<int> pattern) async {
    if (!_canVibrate) return;
    try {
      await Vibration.vibrate(pattern: pattern);
    } catch (_) {
      // Vibration not critical -- swallow platform errors.
    }
  }

  Future<void> _handleTriggerId(String triggerId, {required String source}) async {
    final message = await _databaseHelper.getMessageByTriggerId(triggerId);

    if (message == null) {
      _setStatus('Unknown trigger from $source: $triggerId');
      await _speakSafely('Unknown location or obstacle trigger.');
      return;
    }

    _lastTrigger = triggerId;
    _setStatus('Trigger from $source: $triggerId');
    await _haptic(const [0, 80, 60, 80]);
    await _speakSafely(message);
  }

  Future<void> _handleObstacleWarning(ObstacleWarning warning) async {
    final directionPhrase = _directionPhrase(warning.direction);
    final distanceText = warning.distanceM.toStringAsFixed(1);
    final lead = warning.severity == 'high' ? 'Warning' : 'Caution';
    final sentence = '$lead, obstacle $directionPhrase, $distanceText meters.';
    _setStatus('Obstacle ${warning.severity}: ${warning.direction} ${distanceText}m');
    if (warning.severity == 'high') {
      await _haptic(const [0, 100, 80, 100, 80, 100]);
    } else {
      await _haptic(const [0, 80, 60, 80]);
    }
    await _speakSafely(sentence);
  }

  String _directionPhrase(String direction) {
    switch (direction) {
      case 'left':
        return 'on your left';
      case 'right':
        return 'on your right';
      case 'ahead':
      default:
        return 'ahead';
    }
  }

  Future<void> _handleVoiceCommand(String recognizedText) async {
    final normalizedCommand = recognizedText.toLowerCase().trim();
    if (normalizedCommand.isEmpty) return;

    _lastHeard = normalizedCommand;
    _setStatus('Recognized: $normalizedCommand');

    if (await _handleBasicVoiceCommand(normalizedCommand)) {
      return;
    }

    final triggerId = _mapVoiceCommandToTrigger(normalizedCommand);
    if (triggerId == null) {
      _setStatus('Voice command not mapped: $normalizedCommand');
      await _speakSafely('Command not recognized.');
      return;
    }

    await _handleTriggerId(triggerId, source: 'Voice command');
  }

  Future<bool> _handleBasicVoiceCommand(String command) async {
    if (command.contains('stop listening') ||
        command.contains('mic off') ||
        command.contains('turn off mic') ||
        command.contains('turn off the mic') ||
        command.contains('be quiet') ||
        command.contains('silence') ||
        command.contains('tais toi') ||
        command.contains('tais-toi') ||
        command.contains('arrete') ||
        command.contains('arrête') ||
        command == 'stop') {
      if (_isListening) {
        await _sttService.stopListening();
        _setListening(false);
        _setStatus('Microphone off.');
        await _ttsService.speak('Microphone off.');
      }
      return true;
    }

    if ((command.contains('ouvre gps') ||
            command.contains('ouvre google maps') ||
            command.contains('ouvre la carte') ||
            command.contains('ouvre carte') ||
            command.contains('open map') ||
            command.contains('open the map') ||
            command.contains('open gps') ||
            command.contains('open navigation') ||
            command.contains('show map') ||
            command == 'map' ||
            command == 'gps') &&
        !_isOpeningMap) {
      _isOpeningMap = true;
      try {
        _setStatus('Opening map...');
        if (_isListening) {
          await _sttService.stopListening();
          _setListening(false);
        }
        await _speakSafely('Ouverture de la carte');
        if (!mounted) return true;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MapScreen(
              sttService: _sttService,
              ttsService: _ttsService,
              micActiveNotifier: _micActiveNotifier,
            ),
          ),
        );
        _setStatus('Returned from map screen.');
      } finally {
        _isOpeningMap = false;
      }
      return true;
    }

    if (command.contains('hello') || command.contains('hi')) {
      _setStatus('Greeting received.');
      await _speakSafely('Hello. I am Dourbiya.');
      return true;
    }

    if (command.contains('where am i') || command.contains('where am i now')) {
      if (_lastTrigger == '-') {
        _setStatus('Current location is unknown.');
        await _speakSafely('I do not know your location yet. Say library, cafeteria, or dorm to test guidance.');
      } else {
        final message = await _databaseHelper.getMessageByTriggerId(_lastTrigger);
        final spoken = message ?? 'Your last known trigger is $_lastTrigger.';
        _setStatus('Reporting current location.');
        await _speakSafely(spoken);
      }
      return true;
    }

    if (command.contains('help') || command.contains('what can i say')) {
      _setStatus('Reporting available commands.');
      await _speakSafely(
        'You can say library, cafeteria, dorm, stairs, door, map, where am I, hello, or repeat.',
      );
      return true;
    }

    if (command.contains('repeat') || command.contains('say again')) {
      if (_lastTrigger == '-') {
        _setStatus('No previous guidance to repeat.');
        await _speakSafely('There is no previous guidance to repeat.');
      } else {
        final message = await _databaseHelper.getMessageByTriggerId(_lastTrigger);
        final spoken = message ?? 'Last known trigger is $_lastTrigger.';
        _setStatus('Repeating last guidance.');
        await _speakSafely(spoken);
      }
      return true;
    }

    return false;
  }

  String? _mapVoiceCommandToTrigger(String command) {
    if (command.contains('library')) return 'uni_library';
    if (command.contains('cafeteria') || command.contains('cafe')) return 'uni_cafeteria';
    if (command.contains('dorm') || command.contains('room')) return 'dorm_room_101';
    if (command.contains('stairs')) return 'stairs_down';
    if (command.contains('door')) return 'door_closed';
    return null;
  }

  Future<void> _toggleListening() async {
    await _haptic(const [0, 30]);
    if (!_sttReady) {
      final micReady = await _ensureMicrophonePermission();
      if (!micReady) {
        _setStatus('Microphone permission denied. Please enable it in settings.');
        return;
      }

      try {
        await _sttService.initialize(
          modelAssetPath: 'assets/models/vosk-model-small-en-us-0.15.zip',
          sampleRate: 16000,
        );
        _sttReady = true;
      } catch (error) {
        _setStatus('Speech service not ready: $error');
        return;
      }
    }

    if (_isListening) {
      await _sttService.stopListening();
      _setListening(false);
      _setStatus('Microphone stopped.');
      await _ttsService.speak('Microphone stopped.');
    } else {
      await _ttsService.stop();
      await _sttService.startListening();
      _setListening(true);
      _setStatus('Listening for offline command... Speak now.');
    }
  }

  Future<void> _openMapFromButton() async {
    await _haptic(const [0, 30]);
    if (_isListening) {
      await _sttService.stopListening();
      _setListening(false);
    }
    _setStatus('Opening map...');
    await _speakSafely('Ouverture de la carte');
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapScreen(
          sttService: _sttService,
          ttsService: _ttsService,
          micActiveNotifier: _micActiveNotifier,
        ),
      ),
    );
    _setStatus('Returned from map screen.');
  }

  Future<void> _speakSafely(String message) async {
    if (_isListening) {
      await _sttService.pauseListening();
    }
    if (mounted) setState(() => _isSpeaking = true);

    try {
      await _ttsService.speak(message);
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
      if (_isListening) {
        await _sttService.resumeListening();
      }
    }
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
    });
  }

  @override
  void dispose() {
    _webSocketSub?.cancel();
    _obstacleSub?.cancel();
    _sttResultSub?.cancel();
    _sttPartialSub?.cancel();

    _pulseController.dispose();
    _micActiveNotifier.removeListener(_onMicNotifierChanged);
    _micActiveNotifier.dispose();

    _webSocketService.dispose();
    _sttService.dispose();
    _ttsService.stop();

    super.dispose();
  }

  Color get _micFillColor {
    if (_isSpeaking) return Colors.greenAccent;
    if (_isListening) return Colors.yellow;
    return Colors.transparent;
  }

  Color get _micIconColor {
    if (_isSpeaking || _isListening) return Colors.black;
    return Colors.yellow;
  }

  String get _micStateLabel {
    if (_isSpeaking) return 'SPEAKING';
    if (_isListening) return 'LISTENING';
    return 'TAP TO LISTEN';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleListening,
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Header(),
                const SizedBox(height: 16),
                Expanded(
                  child: Center(
                    child: _MicPulse(
                      controller: _pulseController,
                      showRings: _isListening || _isSpeaking,
                      ringColor: _isSpeaking ? Colors.greenAccent : Colors.yellow,
                      fillColor: _micFillColor,
                      iconColor: _micIconColor,
                      label: _micStateLabel,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _StatusPill(text: _status),
                const SizedBox(height: 12),
                _InfoChip(label: 'Last trigger', value: _lastTrigger),
                const SizedBox(height: 6),
                _InfoChip(label: 'Last heard', value: _lastHeard),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton.icon(
                    onPressed: _openMapFromButton,
                    icon: const Icon(Icons.map, size: 26),
                    label: const Text('OPEN MAP'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.yellow,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(220, 60),
                      textStyle: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(32),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        Image(
          image: AssetImage('assets/images/ept_logo.gif'),
          height: 48,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        SizedBox(height: 6),
        Text(
          'DOURBIYA',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.yellow,
            fontSize: 44,
            fontWeight: FontWeight.w900,
            letterSpacing: 4.0,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Offline Accessibility',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white70,
            fontSize: 16,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

class _MicPulse extends StatelessWidget {
  const _MicPulse({
    required this.controller,
    required this.showRings,
    required this.ringColor,
    required this.fillColor,
    required this.iconColor,
    required this.label,
  });

  final AnimationController controller;
  final bool showRings;
  final Color ringColor;
  final Color fillColor;
  final Color iconColor;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 210,
          height: 210,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, child) {
              final t = controller.value;
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (showRings) ...[
                    _ring(size: 165 + t * 40, opacity: (1 - t) * 0.25),
                    _ring(size: 140 + t * 35, opacity: (1 - t) * 0.45),
                  ],
                  Container(
                    width: 130,
                    height: 130,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: fillColor,
                      border: Border.all(color: Colors.yellow, width: 4),
                    ),
                    child: Icon(Icons.mic, size: 64, color: iconColor),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(
            color: Colors.yellow,
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 2.0,
          ),
        ),
      ],
    );
  }

  Widget _ring({required double size, required double opacity}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: ringColor.withValues(alpha: opacity.clamp(0.0, 1.0)),
          width: 3,
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: Colors.yellow, width: 2),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            '$label:',
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
