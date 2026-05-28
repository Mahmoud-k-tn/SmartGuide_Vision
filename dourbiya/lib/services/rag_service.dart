import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'locale_service.dart';

/// A single piece of knowledge: 1 idea, indexed by tags, available in EN/FR.
class KnowledgeChunk {
  KnowledgeChunk({
    required this.id,
    required this.topic,
    required this.tags,
    required this.textEn,
    required this.textFr,
  });

  final String id;
  final String topic;
  final List<String> tags;
  final String textEn;
  final String textFr;

  String text(AppLocale locale) =>
      locale == AppLocale.fr ? textFr : textEn;

  factory KnowledgeChunk.fromJson(Map<String, dynamic> json) {
    return KnowledgeChunk(
      id: json['id'] as String,
      topic: json['topic'] as String,
      tags: List<String>.from(json['tags'] as List),
      textEn: json['text_en'] as String,
      textFr: json['text_fr'] as String,
    );
  }
}

/// Result of a retrieval query: the chunk + its similarity score.
class _ScoredChunk {
  _ScoredChunk(this.chunk, this.score);
  final KnowledgeChunk chunk;
  final double score;
}

/// Lexical Retrieval-Augmented Generation service.
///
/// Loads a knowledge base of small text chunks from JSON. Given a free-form
/// question, it ranks chunks by a TF-IDF + tag-overlap score and assembles
/// the top-K results into a natural multilingual answer. No model is needed
/// on device -- everything runs as pure Dart, in a few milliseconds.
class RagService {
  RagService._internal();
  static final RagService instance = RagService._internal();

  static const String _knowledgePath = 'assets/rag/knowledge.json';
  static const int _defaultTopK = 5;

  final List<KnowledgeChunk> _chunks = [];

  /// IDF weight per term across the whole corpus.
  final Map<String, double> _idf = {};

  /// Pre-computed TF-IDF vector for each chunk's text+tags.
  final Map<String, Map<String, double>> _chunkVectors = {};

  bool _initialized = false;
  bool get isReady => _initialized;
  int get chunkCount => _chunks.length;

  /// Load the JSON knowledge base and pre-compute term-frequency statistics.
  /// Safe to call multiple times -- subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) return;

    final raw = await rootBundle.loadString(_knowledgePath);
    final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;

    _chunks.clear();
    for (final entry in decoded) {
      _chunks.add(KnowledgeChunk.fromJson(entry as Map<String, dynamic>));
    }

    _buildIndex();
    _initialized = true;
  }

  /// Public retrieval entry-point: returns the top-K most relevant chunks
  /// for the given [question] in the current language. Score is the cosine
  /// similarity between the TF-IDF vectors of the question and each chunk.
  List<KnowledgeChunk> query(
    String question,
    AppLocale locale, {
    int topK = _defaultTopK,
    double minScore = 0.30,
  }) {
    if (!_initialized || _chunks.isEmpty) return [];

    final queryTokens = _tokenize(question.toLowerCase());
    if (queryTokens.isEmpty) return [];

    final queryVector = _tfidfVector(queryTokens);
    if (queryVector.isEmpty) return [];

    final scored = <_ScoredChunk>[];
    for (final chunk in _chunks) {
      final chunkVec = _chunkVectors[chunk.id];
      if (chunkVec == null) continue;

      final cosine = _cosineSimilarity(queryVector, chunkVec);

      // Tag overlap is the strongest signal. The first match contributes
      // moderately; additional matches contribute super-linearly so that a
      // chunk with 2-3 matching tags clearly dominates one with a single
      // accidental tag overlap.
      final tagOverlap = _tagOverlap(queryTokens, chunk.tags);
      final tagBoost = tagOverlap == 0
          ? 0.0
          : 0.25 * tagOverlap + 0.10 * (tagOverlap - 1) * tagOverlap;

      final textBoost = 0.05 * _localeTextOverlap(queryTokens, chunk.text(locale));

      final score = cosine + tagBoost + textBoost;
      scored.add(_ScoredChunk(chunk, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return const [];

    // Confidence floor: with a small corpus a single accidental tag match
    // can push a wrong chunk slightly above zero. Only return a result when
    // the best chunk passes a real threshold.
    if (scored.first.score < minScore) return const [];

    // Then take chunks within 70% of the best score for the answer body.
    final cutoff = scored.first.score * 0.70;
    final filtered = scored.where((sc) => sc.score >= cutoff).toList();
    return filtered.take(topK).map((sc) => sc.chunk).toList(growable: false);
  }

  /// Public generation entry-point: builds a fluent multilingual answer
  /// from the top-K retrieved chunks. Returns null if nothing relevant
  /// was found above the threshold.
  String? generateAnswer(
    String question,
    AppLocale locale, {
    int topK = _defaultTopK,
  }) {
    final results = query(question, locale, topK: topK);
    if (results.isEmpty) return null;

    final connector = _connectorWord(locale);
    final sentences = results.map((c) => c.text(locale)).toList();

    if (sentences.length == 1) return sentences.first;
    if (sentences.length == 2) {
      return '${sentences[0]} $connector ${_lowerFirst(sentences[1])}';
    }

    final head = sentences.sublist(0, sentences.length - 1).join(' ');
    final tail = sentences.last;
    return '$head $connector ${_lowerFirst(tail)}';
  }

  // ────────────────────────────────────────────────────────────────────
  // Internals
  // ────────────────────────────────────────────────────────────────────

  /// Build IDF table over the corpus and pre-compute the TF-IDF vector of
  /// every chunk (tags + EN text + FR text combined). The document space is
  /// "bilingual" so the same vector matches FR or EN queries.
  void _buildIndex() {
    final docFreq = <String, int>{};
    final docTokens = <String, List<String>>{};

    for (final chunk in _chunks) {
      final combined = '${chunk.tags.join(' ')} ${chunk.textEn} ${chunk.textFr}';
      final tokens = _tokenize(combined.toLowerCase());
      docTokens[chunk.id] = tokens;

      final unique = tokens.toSet();
      for (final term in unique) {
        docFreq[term] = (docFreq[term] ?? 0) + 1;
      }
    }

    final docCount = _chunks.length;
    _idf.clear();
    docFreq.forEach((term, df) {
      // Smoothed IDF: log((N + 1) / (df + 1)) + 1
      _idf[term] = log((docCount + 1) / (df + 1)) + 1.0;
    });

    _chunkVectors.clear();
    for (final chunk in _chunks) {
      final tokens = docTokens[chunk.id]!;
      _chunkVectors[chunk.id] = _tfidfVector(tokens);
    }
  }

  /// Compute the TF-IDF vector of an arbitrary token list using [_idf].
  Map<String, double> _tfidfVector(List<String> tokens) {
    if (tokens.isEmpty) return const {};

    final tf = <String, int>{};
    for (final t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }

    final vec = <String, double>{};
    tf.forEach((term, count) {
      final idf = _idf[term];
      if (idf == null) return;
      vec[term] = count * idf;
    });

    return vec;
  }

  /// Standard cosine similarity between two sparse vectors.
  double _cosineSimilarity(Map<String, double> a, Map<String, double> b) {
    if (a.isEmpty || b.isEmpty) return 0.0;
    double dot = 0.0;
    a.forEach((term, valA) {
      final valB = b[term];
      if (valB != null) dot += valA * valB;
    });
    if (dot == 0.0) return 0.0;
    final normA = sqrt(a.values.fold(0.0, (s, v) => s + v * v));
    final normB = sqrt(b.values.fold(0.0, (s, v) => s + v * v));
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (normA * normB);
  }

  /// Count how many query tokens match any tag exactly.
  int _tagOverlap(List<String> queryTokens, List<String> tags) {
    final tagSet = tags.map((t) => t.toLowerCase()).toSet();
    int hits = 0;
    for (final qt in queryTokens) {
      if (tagSet.contains(qt)) hits++;
    }
    return hits;
  }

  /// Light bonus when query tokens appear in the locale-specific text.
  int _localeTextOverlap(List<String> queryTokens, String text) {
    final textTokens = _tokenize(text.toLowerCase()).toSet();
    int hits = 0;
    for (final qt in queryTokens) {
      if (textTokens.contains(qt)) hits++;
    }
    return hits;
  }

  /// Tokenize -- lowercase, strip punctuation, drop stopwords and very short
  /// tokens. Accent-folding is light: we keep accented vowels but normalise
  /// common ascii forms so "francais" and "français" both reduce the same.
  List<String> _tokenize(String text) {
    final lowered = text.toLowerCase();
    final cleaned = lowered
        .replaceAll(RegExp(r'''[.,;:!?()\[\]{}"`'-]'''), ' ')
        .replaceAll(RegExp('[éèêë]'), 'e')
        .replaceAll(RegExp('[àâä]'), 'a')
        .replaceAll(RegExp('[îï]'), 'i')
        .replaceAll(RegExp('[ôö]'), 'o')
        .replaceAll(RegExp('[ûüù]'), 'u')
        .replaceAll(RegExp('[ç]'), 'c');

    final tokens = cleaned
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && t.length >= 2)
        .where((t) => !_stopwords.contains(t))
        .toList(growable: false);

    return tokens;
  }

  String _connectorWord(AppLocale locale) {
    switch (locale) {
      case AppLocale.en:
        return 'Also,';
      case AppLocale.fr:
        return 'De plus,';
    }
  }

  String _lowerFirst(String s) {
    if (s.isEmpty) return s;
    return s.substring(0, 1).toLowerCase() + s.substring(1);
  }

  /// Minimal bilingual stopword list. Kept short on purpose: removing too
  /// many common words hurts recall on a small corpus.
  static const Set<String> _stopwords = {
    // English
    'the', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'of', 'to', 'in', 'on', 'at', 'for', 'with', 'about', 'and',
    'but', 'this', 'that', 'these', 'those', 'it', 'its',
    'do', 'does', 'did', 'have', 'has', 'had',
    'me', 'tell', 'whats', 'what', 'which', 'when', 'how',
    'you', 'we', 'they',
    // French
    'le', 'la', 'les', 'un', 'une', 'des', 'du', 'au', 'aux',
    'et', 'ou', 'mais', 'donc', 'ni', 'car',
    'est', 'sont', 'etait', 'etaient', 'sera', 'seront',
    'ce', 'ces', 'cet', 'cette',
    'je', 'tu', 'il', 'elle', 'nous', 'vous', 'ils', 'elles',
    'dis', 'dit', 'dire', 'parle', 'parler', 'parles', 'moi', 'toi',
    'sur', 'dans', 'avec', 'pour', 'par', 'sans',
    'que', 'qui', 'quoi', 'quel', 'quelle',
  };
}
