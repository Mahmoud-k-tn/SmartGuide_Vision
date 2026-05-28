import 'package:flutter/foundation.dart';

/// Supported app languages.
enum AppLocale { en, fr }

/// Centralised translations + current-language state.
///
/// All TTS phrases and UI labels go through this service so that the rest
/// of the app never hard-codes a language. Subscribe to [notifier] to react
/// to language changes.
class LocaleService {
  LocaleService._internal();
  static final LocaleService instance = LocaleService._internal();

  final ValueNotifier<AppLocale> notifier = ValueNotifier<AppLocale>(AppLocale.en);

  AppLocale get current => notifier.value;

  /// IETF BCP-47 tag used by flutter_tts.setLanguage().
  String get ttsTag {
    switch (current) {
      case AppLocale.en:
        return 'en-US';
      case AppLocale.fr:
        return 'fr-FR';
    }
  }

  /// Path of the Vosk model asset bundled in the APK for the current locale.
  String get voskAssetPath {
    switch (current) {
      case AppLocale.en:
        return 'assets/models/vosk-model-small-en-us-0.15.zip';
      case AppLocale.fr:
        return 'assets/models/vosk-model-small-fr-0.22.zip';
    }
  }

  /// Move to the next language in the cycle EN -> FR -> EN.
  AppLocale cycleNext() {
    final next = AppLocale.values[(current.index + 1) % AppLocale.values.length];
    setLocale(next);
    return next;
  }

  void setLocale(AppLocale locale) {
    if (notifier.value == locale) return;
    notifier.value = locale;
  }

  /// Get a translated string by [key] in the current language.
  String t(String key) {
    final table = _translations[current] ?? _translations[AppLocale.en]!;
    return table[key] ?? _translations[AppLocale.en]![key] ?? key;
  }

  /// Display name of the language (used by the "switch language" button).
  String languageDisplayName(AppLocale locale) {
    switch (locale) {
      case AppLocale.en:
        return 'English';
      case AppLocale.fr:
        return 'Francais';
    }
  }

  /// Direction phrase localisation for obstacle warnings.
  String directionPhrase(String direction) {
    switch (current) {
      case AppLocale.en:
        switch (direction) {
          case 'left':
            return 'on your left';
          case 'right':
            return 'on your right';
          default:
            return 'ahead';
        }
      case AppLocale.fr:
        switch (direction) {
          case 'left':
            return 'sur votre gauche';
          case 'right':
            return 'sur votre droite';
          default:
            return 'devant vous';
        }
    }
  }

  /// Obstacle sentence built from a Pi event.
  String obstacleSentence(String direction, double distanceM, String severity) {
    final dir = directionPhrase(direction);
    final dist = distanceM.toStringAsFixed(1);
    switch (current) {
      case AppLocale.en:
        final lead = severity == 'high' ? 'Warning' : 'Caution';
        return '$lead, obstacle $dir, $dist meters.';
      case AppLocale.fr:
        final lead = severity == 'high' ? 'Attention' : 'Prudence';
        return '$lead, obstacle $dir, a $dist metres.';
    }
  }

  // --------------------------------------------------------------------
  // Translation tables
  // --------------------------------------------------------------------
  static final Map<AppLocale, Map<String, String>> _translations = {
    AppLocale.en: {
      'app.ready': 'Application is ready in offline mode.',
      'app.initializing': 'Initializing offline services...',
      'app.tap_to_listen': 'Ready. Tap anywhere to listen for voice command.',
      'mic.permission_required':
          'Microphone permission is required for speech recognition.',
      'mic.allow_request': 'Please allow microphone permission and try again.',
      'mic.off': 'Microphone off.',
      'mic.stopped': 'Microphone stopped.',
      'mic.listening': 'Listening for offline command... Speak now.',
      'mic.label_listening': 'LISTENING',
      'mic.label_speaking': 'SPEAKING',
      'mic.label_tap': 'TAP TO LISTEN',
      'cmd.not_recognized': 'Command not recognized.',
      'cmd.no_info': 'I do not have information about that yet. Try asking about the school, the parking, the reception, or the football stadium.',
      'cmd.greeting': 'Hello. I am your assistant.',
      'cmd.help_list':
          'You can ask me about the school, the director, the departments, the clubs, the parking, the reception, the stadium, or say stop, open map, hello, or change language.',
      'map.opening': 'Opening map.',
      'lang.switched': 'Language switched to English.',
      'btn.open_map': 'OPEN MAP',
      'btn.change_language': 'LANGUAGE',
      'label.last_heard': 'Last heard',
      'tagline': 'Offline Accessibility',
    },
    AppLocale.fr: {
      'app.ready': 'Application prete en mode hors-ligne.',
      'app.initializing': 'Initialisation des services hors-ligne...',
      'app.tap_to_listen': 'Pret. Touchez l\'ecran pour parler.',
      'mic.permission_required':
          'L\'autorisation du microphone est requise pour la reconnaissance vocale.',
      'mic.allow_request':
          'Veuillez autoriser le microphone puis reessayer.',
      'mic.off': 'Microphone desactive.',
      'mic.stopped': 'Microphone arrete.',
      'mic.listening': 'Ecoute en cours... Parlez maintenant.',
      'mic.label_listening': 'A L\'ECOUTE',
      'mic.label_speaking': 'PARLE',
      'mic.label_tap': 'TOUCHEZ POUR PARLER',
      'cmd.not_recognized': 'Commande non reconnue.',
      'cmd.no_info': 'Je n\'ai pas d\'information sur ce sujet pour le moment. Vous pouvez me demander a propos de l\'ecole, du parking, de la reception ou du stade de football.',
      'cmd.greeting': 'Bonjour. Je suis votre assistant.',
      'cmd.help_list':
          'Vous pouvez me poser des questions sur l\'ecole, le directeur, les departements, les clubs, le parking, la reception, le stade, ou dire stop, ouvre la carte, bonjour, ou changer de langue.',
      'map.opening': 'Ouverture de la carte.',
      'lang.switched': 'Langue changee en francais.',
      'btn.open_map': 'OUVRIR LA CARTE',
      'btn.change_language': 'LANGUE',
      'label.last_heard': 'Dernier mot entendu',
      'tagline': 'Accessibilite hors-ligne',
    },
  };
}
