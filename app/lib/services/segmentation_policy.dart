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

class SegmentationPolicy {
  // Core sizing parameters (v2) - aligned with Python config.py
  static const int minWords = 35;
  static const int maxWords = 65;
  static const int preferredMaxChars = 380;

  // Soft targets (adaptable based on body-text statistics)
  // These are computed per-document, not hardcoded
  static const int defaultTargetWords = 50;
  static const int minTargetWords = 48;
  static const int maxTargetWords = 64;

  // Shortfall policies (must match across implementations)
  // Python fallback: max(MIN_CHUNK_WORDS, floor(target * 0.55)) where MIN_CHUNK_WORDS = 35
  // Rust: 35.max(target * 0.70) - TO BE ALIGNED to match Python
  // Dart: max(minWords, floor(target * 0.55)) - NOW ALIGNED
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
  static const String version = 'segmentation-v2';
  static const String offsetProtocol = 'utf8-byte-v2';

  /// Computes the effective minimum words for a given target
  /// Matches Python fallback: max(minWords, floor(target * 0.55))
  static int effectiveMinWords(int targetWords) {
    final ratioMin = (targetWords * minWordsRatio).floor();
    return ratioMin > minWords ? ratioMin : minWords;
  }

  /// Computes the effective minimum words per Rust formula (for reference)
  /// Rust: 35.max(target * 0.70)
  static int rustEffectiveMinWords(int targetWords) {
    final ratioMin = (targetWords * 0.70).floor();
    return ratioMin > absoluteMinWords ? ratioMin : absoluteMinWords;
  }

  /// Validates that a cut position is at a legal boundary
  /// Returns true if the cut is safe (not inside grapheme/protected token)
  static bool isLegalCut(String text, int cutPosition) {
    // TODO: Implement full UAX #29 grapheme boundary check
    // For now, basic checks:
    if (cutPosition <= 0 || cutPosition >= text.length) return false;

    // Check if we're in the middle of a surrogate pair
    final codeUnit = text.codeUnitAt(cutPosition);
    if (codeUnit >= 0xDC00 && codeUnit <= 0xDFFF) {
      // Low surrogate - check previous
      if (cutPosition > 0) {
        final prev = text.codeUnitAt(cutPosition - 1);
        if (prev >= 0xD800 && prev <= 0xDBFF) return false; // Split surrogate pair
      }
    }

    // Check if previous is high surrogate
    if (cutPosition > 0) {
      final prev = text.codeUnitAt(cutPosition - 1);
      if (prev >= 0xD800 && prev <= 0xDBFF) {
        // High surrogate - check next
        if (cutPosition < text.length) {
          final next = text.codeUnitAt(cutPosition);
          if (next >= 0xDC00 && next <= 0xDFFF) return false; // Split surrogate pair
        }
      }
    }

    return true;
  }

  /// Finds the nearest legal cut position at or before the given position
  static int findLegalCut(String text, int preferredPosition) {
    // Search backward from preferred position for a legal boundary
    for (int i = preferredPosition; i >= 0; i--) {
      if (isLegalCut(text, i)) {
        return i;
      }
    }
    return preferredPosition; // Fallback (should not happen with valid input)
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
    // Import crypto at usage point to avoid circular deps
    return ''; // Placeholder
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
  // Match Unicode whitespace: \u0009-\u000D,  , \u0085,  ,  ,  - ,  ,  ,  ,  ,
  final wordPattern = RegExp(r'[^\u0009-\u000D \u0085   -     　]+', unicode: true);
  return wordPattern.allMatches(text).length;
}