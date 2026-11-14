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

  /// Standard sentence candidate regex conforming to the Golden Rule with multilingual support (LNG-03)
  /// Supports Latin (.!?…), CJK (。\uff01\uff1f), Indic (।॥), Arabic (؟)
  static final RegExp sentenceRegex = RegExp(
    r'([.!?…\u3002\uFF01\uFF1F\u0964\u0965\u061F]+|\.\s?\.\s?\.)([”"’\x27)\]»]*)([\s\u3000]*)(?=[“"‘\x27(\[«¿¡]*([\p{Lu}\p{Lt}\p{N}]|[\u0900-\u097F\u0B80-\u0BFF\u0600-\u06FF\u0590-\u05FF\u3040-\u9FFF\uAC00-\uD7AF]|$))',
    unicode: true,
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

    final prevCode = text.codeUnitAt(b - 1);
    if (_isWs(prevCode) || _isWs(c)) return true;

    // Multilingual sentence terminators and closing quotes are legal cut boundaries
    const legalPunct = {
      0x3002, // 。
      0xFF01, // ！
      0xFF1F, // ？
      0x0964, // ।
      0x0965, // ॥
      0x061F, // ؟
      0x2026, // …
      0x201D, // ”
      0x2019, // ’
      0x00BB, // »
    };
    if (legalPunct.contains(prevCode)) return true;

    // CJK ideographs/syllables: boundary adjacent to CJK character is legal
    final isCjkPrev = (prevCode >= 0x3040 && prevCode <= 0x9FFF) || (prevCode >= 0xAC00 && prevCode <= 0xD7AF);
    final isCjkCurr = (c >= 0x3040 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF);
    if (isCjkPrev || isCjkCurr) return true;

    return false;
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

      // For Latin/ASCII punctuation, require whitespace before next word unless at end
      final isMultilingualTerm = punctGroup.runes.any((r) =>
          r == 0x3002 || r == 0xFF01 || r == 0xFF1F || r == 0x0964 || r == 0x0965 || r == 0x061F);
      final wsGroup = match.group(3) ?? '';
      if (wsGroup.isEmpty && !isMultilingualTerm && whitespaceEnd < text.length) {
        continue;
      }

      if (whitespaceEnd > 0) {
        boundaries.add(whitespaceEnd);
      }
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

  /// Word count utility consistent with top-level countWords (LNG-03)
  static int countWords(String text) {
    if (text.trim().isEmpty) return 0;
    final nonSpaceChars = text.replaceAll(RegExp(r'\s+'), '');
    if (nonSpaceChars.isEmpty) return 0;

    // For CJK / script-without-spaces text (where CJK characters [\u3040-\u9FFF\uAC00-\uD7AF]
    // make up >= 25% of characters), count ~2.5 CJK characters as 1 word unit (LNG-03)
    final cjkMatches = RegExp(r'[\u3040-\u9FFF\uAC00-\uD7AF]').allMatches(nonSpaceChars).length;
    if (cjkMatches / nonSpaceChars.length >= 0.25) {
      final nonCjkText = text.replaceAll(RegExp(r'[\u3040-\u9FFF\uAC00-\uD7AF]+'), ' ');
      final wordPattern = RegExp(r'[^\u0009-\u000D \u0085   -     　]+', unicode: true);
      final nonCjkWords = wordPattern.allMatches(nonCjkText.trim()).length;
      final cjkWords = (cjkMatches / 2.5).ceil();
      return nonCjkWords + cjkWords;
    }

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
int countWords(String text) => SegmentationPolicy.countWords(text);
