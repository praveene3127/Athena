/// Shared Segmentation Policy Contract
///
/// This is the single source of truth for chunking parameters across all execution paths:
/// - Dart (mobile standalone): lossless_chunker.dart
/// - Python (backend): chunker.py
/// - Rust (acceleration): lib.rs (plan_feed_chunks_core)
///
/// Version: segmentation-v2
/// Offset Protocol: utf8-byte-v2 (for cross-platform persisted anchors)

library;

import 'dart:convert';
import 'package:crypto/crypto.dart';

class SegmentationPolicy {
  // Core sizing parameters (v2) - aligned with Python config.py
  static const int minWords = 35;
  static const int maxWords = 65;
  static const int preferredMaxChars = 380;
  static const int defaultTargetWords = 50;
  static const int chunkIdPadWidth = 6;

  // Document states according to canonical athena-contract.json
  static const List<String> documentStates = [
    'queued',
    'processing',
    'partially_readable',
    'paused',
    'interrupted',
    'ready',
    'failed',
    'unsupported',
    'deleted',
  ];

  static const String methodChannel = 'athena/foreground_ingestion';
  static const List<String> methodChannelMethods = [
    'startForegroundService',
    'updateForegroundProgress',
    'stopForegroundService',
    'requestNotificationPermission',
  ];
  static const int minTargetWords = 48;
  static const int maxTargetWords = 64;

  // Shortfall policies (must match across implementations)
  // Python fallback: max(MIN_CHUNK_WORDS, floor(target * 0.55)) where MIN_CHUNK_WORDS = 35
  // Rust: 35.max(target * 0.55)
  // Dart: max(minWords, floor(target * 0.55)) - ALIGNED
  static double get minWordsRatio => 0.55;
  static int get absoluteMinWords => 35;

  // Overflow penalties (cost function weights)
  static const double charOverflowWeight = 12.0;
  static const double wordOverflowWeight = 8.0;
  static const double shortfallWeight = 2.0;

  // Boundary preferences (in priority order)
  static const List<String> boundaryPriority = [
    'paragraph',
    'sentence',
    'clause',
    'word',
  ];

  // Atomic overflow behavior
  static const bool preserveAtomicTokens = true;
  static const String atomicOverflowReason = 'atomic_token';

  // Protected token patterns (never split inside these)
  static const Set<String> protectedPatterns = {
    'url',
    'doi',
    'email',
    'decimal',
    'compound_word',
    'hyphenated_name',
    'numeric_expression',
    'cjk_token',
    'grapheme_cluster',
  };

  // Version for migration tracking
  static const String version = 'segmentation-v3';
  static const String offsetProtocol = 'utf8-byte-v3';

  /// Standard sentence candidate regex conforming to the Golden Rule
  static final RegExp sentenceRegex = RegExp(
    r'([.!?…]+|\.\s?\.\s?\.)([”"’\x27)\]»]*)(\s+)(?=[“"‘\x27(\[«]*[A-Z0-9¿¡])',
  );

  /// Extended abbreviations list preventing spurious sentence cuts
  static const Set<String> abbreviations = {
    'mr.', 'mrs.', 'ms.', 'dr.', 'prof.', 'st.', 'inc.', 'ltd.', 'co.',
    'vs.', 'etc.', 'e.g.', 'i.e.', 'cf.', 'al.', 'vol.', 'no.', 'ed.',
    'eds.', 'pp.', 'p.', 'rev.', 'gen.', 'sen.', 'rep.', 'gov.', 'pres.',
    'sec.', 'dept.', 'univ.', 'assn.', 'corp.', 'jan.', 'feb.', 'mar.',
    'apr.', 'jun.', 'jul.', 'aug.', 'sep.', 'sept.', 'oct.', 'nov.', 'dec.',
    'ca.', 'jr.', 'sr.', 'fig.', 'figs.', 'ch.', 'ref.', 'refs.', 'eq.', 'eqs.'
  };

  /// Computes the effective minimum words for a given target
  /// Matches Python fallback: max(minWords, floor(target * 0.55))
  static int effectiveMinWords(int targetWords) {
    final ratioMin = (targetWords * minWordsRatio).floor();
    return ratioMin > minWords ? ratioMin : minWords;
  }

  /// Computes the effective minimum words per Rust formula
  static int rustEffectiveMinWords(int targetWords) {
    final ratioMin = (targetWords * 0.55).floor();
    return ratioMin > absoluteMinWords ? ratioMin : absoluteMinWords;
  }

  /// Validates that a cut position is at a legal boundary (Zero Mid-Word Cuts, FP-1)
  /// Returns true if cut is safe (at boundary or adjacent to whitespace, not in surrogate pair)
  static bool isLegalCut(String text, int b) {
    if (b <= 0 || b >= text.length) return true;

    // Check surrogate pairs
    final c = text.codeUnitAt(b);
    if (c >= 0xDC00 && c <= 0xDFFF) {
      final prev = text.codeUnitAt(b - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) return false;
    }
    if (b > 0) {
      final prev = text.codeUnitAt(b - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) {
        if (c >= 0xDC00 && c <= 0xDFFF) return false;
      }
    }

    return _isWs(text.codeUnitAt(b - 1)) || _isWs(text.codeUnitAt(b));
  }

  static bool _isWs(int c) =>
      c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0x85 || c == 0xA0 ||
      c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
      c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;

  /// Finds sentence boundaries matching the golden rule splitter (FP-2).
  /// Slices at end of trailing whitespace so each sentence maintains contiguous invariant.
  static List<int> findSentenceBoundaries(String text) {
    if (text.isEmpty) return const [];
    final boundaries = <int>[];
    for (final match in sentenceRegex.allMatches(text)) {
      final punctGroup = match.group(1)!;
      final punctEnd = match.start + punctGroup.length;
      final whitespaceEnd = match.end;

      // Decimal guard: e.g. 3.14 or 2.0
      if (punctEnd > 0 && punctEnd < text.length) {
        final prevChar = text.codeUnitAt(punctEnd - 1);
        final nextChar = text.codeUnitAt(punctEnd);
        if (prevChar >= 48 && prevChar <= 57 && nextChar >= 48 && nextChar <= 57) {
          continue;
        }
      }

      // Check preceding token for abbreviation or initial
      var tokenStart = match.start;
      while (tokenStart > 0 && !_isWs(text.codeUnitAt(tokenStart - 1))) {
        tokenStart--;
      }
      final token = text.substring(tokenStart, punctEnd).toLowerCase();
      if (abbreviations.contains(token)) {
        continue;
      }
      // Single letter initial guard e.g. "J." in "J. K. Rowling"
      if (token.length == 2 &&
          ((token.codeUnitAt(0) >= 97 && token.codeUnitAt(0) <= 122) ||
           (token.codeUnitAt(0) >= 65 && token.codeUnitAt(0) <= 90)) &&
          token.endsWith('.')) {
        continue;
      }

      boundaries.add(whitespaceEnd);
    }
    return boundaries;
  }

  /// Builds a byte-offset translation table from UTF-8 to UTF-16 code units (FP-1).
  static List<int> buildUtf8ToUtf16Map(String text) {
    final utf8Bytes = utf8.encode(text);
    final map = List<int>.filled(utf8Bytes.length + 1, 0);
    int u16Offset = 0;
    int u8Offset = 0;
    for (final rune in text.runes) {
      final charLenU16 = rune > 0xFFFF ? 2 : 1;
      final charLenU8 = rune <= 0x7F
          ? 1
          : (rune <= 0x7FF
              ? 2
              : (rune <= 0xFFFF ? 3 : 4));
      for (int i = 0; i < charLenU8; i++) {
        map[u8Offset + i] = u16Offset;
      }
      u8Offset += charLenU8;
      u16Offset += charLenU16;
    }
    map[utf8Bytes.length] = text.length;
    return map;
  }

  /// Finds the nearest legal cut position at or before the given position
  static int findLegalCut(String text, int preferredPosition) {
    if (preferredPosition <= 0) return 0;
    if (preferredPosition >= text.length) return text.length;
    for (int i = preferredPosition; i >= 0; i--) {
      if (isLegalCut(text, i)) {
        return i;
      }
    }
    return preferredPosition;
  }

  /// Word count utility consistent with top-level countWords
  static int countWords(String text) {
    if (text.trim().isEmpty) return 0;
    final wordPattern = RegExp(r'[^\u0009-\u000D \u0085   -     　]+', unicode: true);
    return wordPattern.allMatches(text).length;
  }
}

/// Result of a segmentation operation with full audit trail
class SegmentationResult {
  final List<ChunkRange> ranges;
  final String canonicalHash;
  final String policyVersion;
  final List<SegmentationNote> notes;

  SegmentationResult({
    required this.ranges,
    required this.canonicalHash,
    required this.policyVersion,
    this.notes = const [],
  });

  /// Validates lossless reconstruction
  bool validate(String canonicalText) {
    final reconstructed = ranges.map((r) => canonicalText.substring(r.start, r.end)).join();
    return reconstructed == canonicalText && _sha256(reconstructed) == canonicalHash;
  }

  String _sha256(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }
}

/// A single chunk range with metadata
class ChunkRange {
  final int start;
  final int end;
  final int wordCount;
  final String boundaryMethod;
  final String? overflowReason;
  final String? sectionTitle;

  ChunkRange({
    required this.start,
    required this.end,
    required this.wordCount,
    required this.boundaryMethod,
    this.overflowReason,
    this.sectionTitle,
  });

  int get length => end - start;
}

/// Diagnostic note for audit trail
class SegmentationNote {
  final String type; // 'info', 'warning', 'atomic_overflow', 'boundary_fallback'
  final String message;
  final int? position;

  SegmentationNote({
    required this.type,
    required this.message,
    this.position,
  });
}

/// Word count utility - consistent across all implementations
/// Uses Unicode whitespace for cross-platform consistency
int countWords(String text) {
  if (text.trim().isEmpty) return 0;
  final wordPattern = RegExp(r'[^\u0009-\u000D \u0085   -     　]+', unicode: true);
  return wordPattern.allMatches(text).length;
}
