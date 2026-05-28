import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:vibration/vibration.dart';

import '../map_screen.dart';
import '../services/locale_service.dart';
import '../services/rag_service.dart';
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
  final TtsService _ttsService = TtsService();
  final SttService _sttService = SttService();
  final WebSocketService _webSocketService = WebSocketService();
  final LocaleService _locale = LocaleService.instance;
  final RagService _rag = RagService.instance;

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
  bool _isSwitchingLanguage = false;
  String _status = '';
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
    _locale.notifier.addListener(_onLocaleChanged);
    _status = _locale.t('app.initializing');
    _bootstrap();
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    try {
      await _rag.initialize();
      await _ttsService.init(initialLanguage: _locale.ttsTag);

      _canVibrate = await Vibration.hasVibrator();

      final micReady = await _ensureMicrophonePermission();
      if (!micReady) {
        _setStatus(_locale.t('mic.permission_required'));
        await _speakSafely(_locale.t('mic.allow_request'));
        return;
      }

      // Subscribe to STT streams first so they exist before the engine
      // emits any partial/final text.
      _sttResultSub = _sttService.resultStream.listen((recognizedText) async {
        await _handleVoiceCommand(recognizedText);
      });

      _sttPartialSub = _sttService.partialStream.listen((partialText) {
        final normalized = partialText.trim();
        if (normalized.isEmpty) return;
        _setStatus('${_locale.t('label.last_heard')}: $normalized');
      });

      _setStatus('Loading speech model...');
      await _loadSttForCurrentLocale(speakOnSuccess: false);

      // WebSocket connect is fire-and-forget: the Pi may be off, and the
      // 3-second handshake timeout must not delay the mic becoming usable.
      unawaited(_connectWebSocketInBackground());

      await _speakSafely(_locale.t('app.ready'));
      _setStatus(_locale.t('app.tap_to_listen'));
    } catch (error) {
      _setStatus('Initialization failed: $error');
    }
  }

  Future<void> _connectWebSocketInBackground() async {
    try {
      await _webSocketService.connect();
    } catch (_) {
      // Pi unreachable -- stay in standalone mode.
    }
    if (!mounted) return;

    _obstacleSub = _webSocketService.obstacleWarningStream.listen((warning) async {
      await _handleObstacleWarning(warning);
    });
  }

  /// (Re)load the Vosk model that matches the current language. Returns true
  /// if STT is ready after the call.
  Future<bool> _loadSttForCurrentLocale({bool speakOnSuccess = true}) async {
    final assetPath = _locale.voskAssetPath;
    try {
      if (_sttReady) {
        final ok = await _sttService.switchModel(assetPath);
        _sttReady = ok;
      } else {
        await _sttService.initialize(modelAssetPath: assetPath);
        _sttReady = true;
      }
      if (_sttReady && speakOnSuccess) {
        await _speakSafely(_locale.t('lang.switched'));
      }
      return _sttReady;
    } catch (error) {
      _sttReady = false;
      _setStatus('Speech model load failed: $error');
      await _speakSafely(_locale.t('lang.stt_unavailable'));
      return false;
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

  Future<void> _handleObstacleWarning(ObstacleWarning warning) async {
    final sentence = _locale.obstacleSentence(
      warning.direction,
      warning.distanceM,
      warning.severity,
    );
    _setStatus(
      'Obstacle ${warning.severity}: ${warning.direction} '
      '${warning.distanceM.toStringAsFixed(1)}m',
    );
    if (warning.severity == 'high') {
      await _haptic(const [0, 100, 80, 100, 80, 100]);
    } else {
      await _haptic(const [0, 80, 60, 80]);
    }
    await _speakSafely(sentence);
  }

  Future<void> _handleVoiceCommand(String recognizedText) async {
    final normalizedCommand = recognizedText.toLowerCase().trim();
    if (normalizedCommand.isEmpty) return;

    _lastHeard = normalizedCommand;
    _setStatus('${_locale.t('label.last_heard')}: $normalizedCommand');

    if (await _handleBasicVoiceCommand(normalizedCommand)) {
      return;
    }

    // Fallback: try the RAG knowledge base for free-form questions.
    final ragAnswer = _rag.generateAnswer(normalizedCommand, _locale.current);
    if (ragAnswer != null) {
      _setStatus('RAG: ${normalizedCommand.length > 40 ? "${normalizedCommand.substring(0, 40)}..." : normalizedCommand}');
      await _speakSafely(ragAnswer);
      return;
    }

    // Nothing matched confidently -- be honest about it.
    _setStatus(_locale.t('cmd.no_info'));
    await _speakSafely(_locale.t('cmd.no_info'));
  }

  Future<bool> _handleBasicVoiceCommand(String command) async {
    // ── Language switching (recognised in any of the 3 languages) ──
    if (_isLanguageSwitchCommand(command)) {
      await _cycleLanguage();
      return true;
    }

    // ── Stop mic ──
    if (_matchesAny(command, _stopMicKeywords)) {
      if (_isListening) {
        await _sttService.stopListening();
        _setListening(false);
        _setStatus(_locale.t('mic.off'));
        await _ttsService.speak(_locale.t('mic.off'));
      }
      return true;
    }

    // ── Open map ──
    if (_matchesAny(command, _openMapKeywords) && !_isOpeningMap) {
      _isOpeningMap = true;
      try {
        _setStatus(_locale.t('map.opening'));
        if (_isListening) {
          await _sttService.stopListening();
          _setListening(false);
        }
        await _speakSafely(_locale.t('map.opening'));
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

    // ── Greeting ──
    if (_matchesAny(command, _greetingKeywords)) {
      await _speakSafely(_locale.t('cmd.greeting'));
      return true;
    }

    // ── Help ──
    if (_matchesAny(command, _helpKeywords)) {
      await _speakSafely(_locale.t('cmd.help_list'));
      return true;
    }

    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // Voice-command keyword tables (trilingual)
  // ────────────────────────────────────────────────────────────────────

  static const _stopMicKeywords = [
    // English
    'stop listening', 'mic off', 'turn off mic', 'turn off the mic',
    'be quiet', 'silence', 'stop',
    // French
    'tais toi', 'tais-toi', 'arrete', 'arrête',
    'coupe le micro', 'eteins le micro',
  ];

  static const _openMapKeywords = [
    'ouvre gps', 'ouvre google maps', 'ouvre la carte', 'ouvre carte',
    'open map', 'open the map', 'open gps', 'open navigation',
    'show map', 'map', 'gps',
    'carte', 'la carte',
  ];

  static const _greetingKeywords = [
    'hello', 'hi',
    'bonjour', 'salut',
  ];

  static const _helpKeywords = [
    'help', 'what can i say',
    'aide', 'aidez moi', 'que puis je dire',
  ];

  static const _languageSwitchKeywords = [
    'change language', 'switch language', 'language',
    'francais', 'français', 'english',
    'changer langue', 'changer de langue', 'parler francais', 'parler anglais',
    'langue',
  ];

  bool _isLanguageSwitchCommand(String command) =>
      _matchesAny(command, _languageSwitchKeywords);

  bool _matchesAny(String command, List<String> keywords) {
    for (final kw in keywords) {
      if (command == kw || command.contains(kw)) return true;
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────
  // Language switching
  // ────────────────────────────────────────────────────────────────────

  Future<void> _cycleLanguage() async {
    if (_isSwitchingLanguage) return;
    _isSwitchingLanguage = true;
    try {
      final wasListening = _isListening;
      if (wasListening) {
        await _sttService.stopListening();
        _setListening(false);
      }
      _locale.cycleNext();
      await _ttsService.setLanguage(_locale.ttsTag);
      await _loadSttForCurrentLocale();
      if (wasListening && _sttReady) {
        await _sttService.startListening();
        _setListening(true);
      }
      _setStatus(_locale.t('app.tap_to_listen'));
    } finally {
      _isSwitchingLanguage = false;
    }
  }

  // ────────────────────────────────────────────────────────────────────

  Future<void> _toggleListening() async {
    await _haptic(const [0, 30]);
    if (!_sttReady) {
      final micReady = await _ensureMicrophonePermission();
      if (!micReady) {
        _setStatus(_locale.t('mic.permission_required'));
        return;
      }
      final ok = await _loadSttForCurrentLocale(speakOnSuccess: false);
      if (!ok) return;
    }

    if (_isListening) {
      await _sttService.stopListening();
      _setListening(false);
      _setStatus(_locale.t('mic.stopped'));
      await _ttsService.speak(_locale.t('mic.stopped'));
    } else {
      await _ttsService.stop();
      try {
        await _sttService.startListening();
        _setListening(true);
        _setStatus(_locale.t('mic.listening'));
      } catch (error) {
        _setListening(false);
        _setStatus('Speech engine busy. Try again in a moment.');
      }
    }
  }

  Future<void> _openMapFromButton() async {
    await _haptic(const [0, 30]);
    if (_isListening) {
      await _sttService.stopListening();
      _setListening(false);
    }
    _setStatus(_locale.t('map.opening'));
    await _speakSafely(_locale.t('map.opening'));
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
    _obstacleSub?.cancel();
    _sttResultSub?.cancel();
    _sttPartialSub?.cancel();

    _pulseController.dispose();
    _micActiveNotifier.removeListener(_onMicNotifierChanged);
    _micActiveNotifier.dispose();
    _locale.notifier.removeListener(_onLocaleChanged);

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
    if (_isSpeaking) return _locale.t('mic.label_speaking');
    if (_isListening) return _locale.t('mic.label_listening');
    return _locale.t('mic.label_tap');
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
                  _Header(tagline: _locale.t('tagline')),
                  const SizedBox(height: 8),
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
                  const SizedBox(height: 8),
                  _StatusPill(text: _status),
                  const SizedBox(height: 8),
                  _InfoChip(label: _locale.t('label.last_heard'), value: _lastHeard),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _openMapFromButton,
                          icon: const Icon(Icons.map, size: 22),
                          label: Text(_locale.t('btn.open_map')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.yellow,
                            foregroundColor: Colors.black,
                            minimumSize: const Size.fromHeight(52),
                            textStyle: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _cycleLanguage,
                          icon: const Icon(Icons.translate, size: 22),
                          label: Text(_locale.languageDisplayName(_locale.current)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            minimumSize: const Size.fromHeight(52),
                            textStyle: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                          ),
                        ),
                      ),
                    ],
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
  const _Header({required this.tagline});
  final String tagline;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Image(
          image: AssetImage('assets/images/ept_logo.gif'),
          height: 48,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
        const SizedBox(height: 6),
        const Text(
          'DOURBIYA',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.yellow,
            fontSize: 44,
            fontWeight: FontWeight.w900,
            letterSpacing: 4.0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          tagline,
          textAlign: TextAlign.center,
          style: const TextStyle(
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
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 16),
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
