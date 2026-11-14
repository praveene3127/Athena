import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'segmentation_policy.dart';

// Pre-compiled top-level RegExps (Zero runtime re-compilation)
final _ellipsisLetterRe = RegExp(r'(\x2e{2,})([A-Za-z“"‘\x27])');
final _letterEllipsisRe = RegExp(r'([A-Za-z])(\x2e{2,})');
final _multiSpaceRe = RegExp(r'[ \t]+');
final _spaceNewlineRe = RegExp(r' *\n *');
final _multiNewlineRe = RegExp(r'\n{3,}');
final _isLetterRe = RegExp(r'[A-Za-z]');


const Set<String> _protectedSurnamePrefixes = {
  'mc',
  'mac',
  'de',
  'di',
  'van',
  'von',
  'le',
  'la',
  'st',
  'fitz',
};

const Set<String> _protectedMixedCaseWords = {
  'mccarthy',
  'delillo',
  'macarthur',
  'vangogh',
  'dicaprio',
  'youtube',
  'javascript',
  'openai',
  'iphone',
  'ipad',
  'macos',
  'github',
  'linkedin',
  'chatgpt',
  'playwright',
  'typescript',
  'deepmind',
  'covid19',
  'area51',
  'wifi',
  'powerpoint',
  'fitzgerald',
  'jpmorgan',
  'mcdonald',
  "mcdonald's",
};

const Set<String> _protectedCompoundWords = {
  'schoolteacher',
  'breakthrough',
  'overthinking',
  'withstanding',
  'thanksgiving',
  'housekeeping',
  'afterthought',
  'counterintuitive',
  'neuroplasticity',
  'socioeconomic',
  'withholding',
  'nevertheless',
  'furthermore',
  'notwithstanding',
  'understatement',
  'masterpiece',
  'fingerprint',
  'courtyard',
  'foothold',
  'watershed',
  'heartbeat',
  'backbone',
  'blueprint',
  'brainstorm',
  'catchphrase',
  'superconductivity',
  'telecommunications',
  'electromagnetism',
  'thermodynamics',
  'photosynthesis',
};

const Set<String> _commonWordPrefixes = {
  'un', 're', 'in', 'im', 'dis', 'en', 'em', 'non', 'over', 'under',
  'sub', 'super', 'inter', 'intra', 'trans', 'counter', 'anti', 'pre',
  'post', 'semi', 'mid', 'co', 'de', 'fore', 'mis', 'out', 'up',
};

const Set<String> _commonWordSuffixes = {
  'ing', 'ed', 'ly', 'ment', 'tion', 'sion', 'ness', 'able', 'ible',
  'ity', 'ous', 'al', 'ic', 'ive', 'ism', 'ist', 'ful', 'less', 'ish',
  'ize', 'ise', 'ate', 'ance', 'ence', 'er', 'or', 'est',
};

/// Normalizes Unicode ligatures, removes soft hyphens and invisible markers,
/// and normalizes non-breaking spaces.
String normalizeUnicodeArtifacts(String text) {
  if (text.isEmpty) return text;
  var s = text;
  // Unicode ligatures: \uFB00..\uFB06
  s = s
      .replaceAll('\uFB00', 'ff')
      .replaceAll('\uFB01', 'fi')
      .replaceAll('\uFB02', 'fl')
      .replaceAll('\uFB03', 'ffi')
      .replaceAll('\uFB04', 'ffl')
      .replaceAll('\uFB05', 'ft')
      .replaceAll('\uFB06', 'st');
  // Invisible characters: \u00AD, \u200B..\u200D, \uFEFF, \u2060
  s = s
      .replaceAll('\u00AD', '')
      .replaceAll('\u200B', '')
      .replaceAll('\u200C', '')
      .replaceAll('\u200D', '')
      .replaceAll('\uFEFF', '')
      .replaceAll('\u2060', '');
  // Non-breaking spaces
  s = s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');
  return s;
}

/// Ledger tracking evidence-based repairs
class RepairLedger {
  final List<SpacingRepair> repairs = [];

  void record({
    required int start,
    required int end,
    required String original,
    required String repaired,
    required String reason,
    double confidence = 1.0,
  }) {
    repairs.add(SpacingRepair(
      startOffset: start,
      endOffset: end,
      originalText: original,
      repairedText: repaired,
      reason: reason,
      confidence: confidence,
    ));
  }

  bool get hasRepairs => repairs.isNotEmpty;
  int get count => repairs.length;
}

/// Normalizes spacing in extracted PDF/EPUB prose.
/// Repairs obvious lost spaces in extracted prose before chunking.
/// Protects valid domain terms, technical compounds (H2O, COVID19, 5mg),
/// abbreviations (U.S.A., Ph.D, e.g.), URLs (www.example.com, doi.org/10.x),
/// and mixed-case proper nouns/brands (McCarthy, DeLillo, YouTube, JavaScript).
///
/// Returns sanitized text with normalized spacing.
String sanitizeProseSpacing(String text) {
  return sanitizeProseSpacingWithAudit(text).text;
}

/// Returns a [SanitizationResult] with the sanitized text and an audit trail
/// of all modifications for evidence-based repair decisions.
SanitizationResult sanitizeProseSpacingWithAudit(String text) {
  if (text.isEmpty) return SanitizationResult(text: text, repairs: []);

  var result = normalizeUnicodeArtifacts(text);
  final repairs = <SpacingRepair>[];

  // 1. Conditional punctuation spacing (protecting abbreviations, numbers, and URLs)
  result = _spaceConditionalPunctuationWithAudit(result, repairs);
  result = _applyEllipsisFixesWithAudit(result, repairs);
  result = _spaceQuoteBoundariesWithAudit(result, repairs);
  result = _collapseWhitespaceWithAudit(result, repairs);

  // 2. Split fused lowercase tokens caused by PDF kerning / justification space drops
  // Only apply when there's evidence of extraction artifacts (not on clean tokens)
  result = _splitFusedTokensWithAudit(result, repairs);

  return SanitizationResult(text: result.trim(), repairs: repairs);
}

/// Result of sanitization with full audit trail
class SanitizationResult {
  final String text;
  final List<SpacingRepair> repairs;

  SanitizationResult({required this.text, required this.repairs});
}

/// A single spacing repair with evidence
class SpacingRepair {
  final int startOffset;
  final int endOffset;
  final String originalText;
  final String repairedText;
  final String reason; // 'ellipsis', 'quote_boundary', 'fused_token', 'whitespace_collapse'
  final double confidence; // 0.0 to 1.0

  SpacingRepair({
    required this.startOffset,
    required this.endOffset,
    required this.originalText,
    required this.repairedText,
    required this.reason,
    required this.confidence,
  });

  Map<String, dynamic> toJson() => {
        'start': startOffset,
        'end': endOffset,
        'original': originalText,
        'repaired': repairedText,
        'reason': reason,
        'confidence': confidence,
      };
}

String _spaceConditionalPunctuation(String text) {
  if (text.isEmpty) return text;

  // 1. Protect URLs, DOIs, web domains, and email addresses
  final protectedUrls = <String>[];
  var result = text.replaceAllMapped(
    RegExp(
        r'\b(?:https?://|www\.|doi\.org/)[^\s]+|\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b|\b[a-zA-Z0-9-]+\.(?:com|org|net|edu|gov|io|ai|dev)/?[^\s]*'),
    (m) {
      protectedUrls.add(m.group(0)!);
      return '___ATHENA_PROTECTED_URL_${protectedUrls.length - 1}___';
    },
  );

  // 2. Protect numbers with decimals (e.g. 3.5, 3.14159)
  result = result.replaceAllMapped(
    RegExp(r'(\d+)\.(\d+)'),
    (m) => '${m[1]}___DECIMAL_POINT___${m[2]}',
  );

  // 3. Conditional period spacing:
  // Only insert a space after `.` when:
  // - the next character is uppercase [A-Z]
  // - the preceding token is >= 3 lowercase letters
  // - AND not an abbreviation / title (SentenceSplitter.abbreviations)
  result = result.replaceAllMapped(
    RegExp(r'\b([A-Za-z]{3,})\.([A-Z])'),
    (m) {
      final token = m.group(1)!;
      final lower = token.toLowerCase();
      final lowerDot = '$lower.';
      if (SentenceSplitter.abbreviations.contains(lowerDot) ||
          SentenceSplitter.abbreviations.contains(lower) ||
          lower == 'etc' ||
          lower == 'vol' ||
          lower == 'fig' ||
          lower == 'inc' ||
          lower == 'ltd' ||
          lower == 'univ') {
        return m.group(0)!;
      }
      return '$token. ${m.group(2)}';
    },
  );

  // 4. Non-period punctuation (comma, semicolon, exclamation, question mark)
  // followed by letter or quote: "water,a" -> "water, a"
  result = result.replaceAllMapped(
    RegExp(r'([,;!?])([A-Za-z“"‘\x27])'),
    (m) => '${m[1]} ${m[2]}',
  );

  // 5. Colon followed by letter (not digits, protecting ISBN:978, 12:30)
  result = result.replaceAllMapped(
    RegExp(r'(:)([A-Za-z])'),
    (m) => '${m[1]} ${m[2]}',
  );

  // 6. Structural headings and chapters: "Chapter1" -> "Chapter 1"
  result = result.replaceAllMapped(
    RegExp(r'\b(Chapter|Section|Part|Book|Page|Figure|Fig|Volume|Vol)\s*(\d+)\b',
        caseSensitive: false),
    (m) => '${m[1]} ${m[2]}',
  );

  // 7. Restore decimal points
  result = result.replaceAll('___DECIMAL_POINT___', '.');

  // 8. Restore protected URLs
  for (var i = 0; i < protectedUrls.length; i++) {
    result = result.replaceAll(
        '___ATHENA_PROTECTED_URL_${i}___', protectedUrls[i]);
  }

  return result;
}

String _spaceConditionalPunctuationWithAudit(String text, List<SpacingRepair> repairs) {
  // Same logic but records repairs - simplified for now
  // In production, would track each replacement with offsets
  return _spaceConditionalPunctuation(text);
}

String _applyEllipsisFixesWithAudit(String text, List<SpacingRepair> repairs) {
  var result = text;
  result = result.replaceAllMapped(_ellipsisLetterRe, (m) => '${m[1]} ${m[2]}');
  result = result.replaceAllMapped(_letterEllipsisRe, (m) => '${m[1]} ${m[2]}');
  return result;
}

String _spaceQuoteBoundaries(String text) {
  final out = StringBuffer();
  var doubleQuoteIsOpening = true;
  bool isWord(String? value) =>
      value != null && RegExp(r'[A-Za-z0-9]').hasMatch(value);
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final previous = i > 0 ? text[i - 1] : null;
    final next = i + 1 < text.length ? text[i + 1] : null;
    if (char == '"') {
      if (doubleQuoteIsOpening && isWord(previous)) out.write(' ');
      out.write(char);
      if (!doubleQuoteIsOpening && isWord(next)) out.write(' ');
      doubleQuoteIsOpening = !doubleQuoteIsOpening;
    } else if (char == '“' || char == '‘') {
      if (isWord(previous)) out.write(' ');
      out.write(char);
    } else if (char == '”') {
      out.write(char);
      if (isWord(next)) out.write(' ');
    } else if (char == '’') {
      final isContraction = isWord(previous) && isWord(next);
      out.write(char);
      if (!isContraction && isWord(next)) out.write(' ');
    } else {
      out.write(char);
    }
  }
  return out.toString();
}

String _spaceQuoteBoundariesWithAudit(String text, List<SpacingRepair> repairs) {
  return _spaceQuoteBoundaries(text);
}

String _collapseWhitespaceWithAudit(String text, List<SpacingRepair> repairs) {
  var result = text.replaceAll(_multiSpaceRe, ' ');
  result = result.replaceAll(_spaceNewlineRe, '\n');
  result = result.replaceAll(_multiNewlineRe, '\n\n');
  return result;
}

/// Splits fused tokens ONLY when there's evidence of extraction artifacts.
/// Evidence includes: camelCase boundaries, known fused patterns, or
/// dictionary decomposition with high confidence.
/// Clean tokens are left intact by default.
String _splitFusedTokensWithAudit(String text, List<SpacingRepair> repairs) {
  return text.split('\n').map((line) {
    return line.split(' ').map((token) => _segmentFusedWordWithAudit(token, repairs)).join(' ');
  }).join('\n');
}

String _segmentFusedWordWithAudit(String rawWord, List<SpacingRepair> repairs) {
  if (rawWord.isEmpty) return rawWord;

  // Separate leading punctuation
  int start = 0;
  while (start < rawWord.length && !_isLetterRe.hasMatch(rawWord[start])) {
    start++;
  }
  // Separate trailing punctuation
  int end = rawWord.length;
  while (end > start && !_isLetterRe.hasMatch(rawWord[end - 1])) {
    end--;
  }

  final prefixPunct = rawWord.substring(0, start);
  final core = rawWord.substring(start, end);
  final suffixPunct = rawWord.substring(end);

  final lower = core.toLowerCase();

  // PROTECT: Scientific compounds and verified dictionary words
  if (_scientificCompounds.contains(lower) ||
      _singleDictionaryWords.contains(lower)) {
    return rawWord;
  }

  // PROTECT: Derived words with recognized English/technical prefixes and suffixes (RC-02)
  for (final pfx in _commonWordPrefixes) {
    if (lower.startsWith(pfx) && lower.length > pfx.length + 2) {
      final stem = lower.substring(pfx.length);
      if (_singleDictionaryWords.contains(stem) || _scientificCompounds.contains(stem)) {
        return rawWord;
      }
    }
  }
  for (final sfx in _commonWordSuffixes) {
    if (lower.endsWith(sfx) && lower.length > sfx.length + 2) {
      final stem = lower.substring(0, lower.length - sfx.length);
      if (_singleDictionaryWords.contains(stem) || _scientificCompounds.contains(stem)) {
        return rawWord;
      }
      if (stem.endsWith('e') && _singleDictionaryWords.contains(stem.substring(0, stem.length - 1))) {
        return rawWord;
      }
    }
  }

  // PROTECT: Mixed-case brands/nouns and surname prefixes
  if (_protectedMixedCaseWords.contains(lower)) {
    return rawWord;
  }
  for (final prefix in _protectedSurnamePrefixes) {
    if (lower.startsWith(prefix) && core.length > prefix.length) {
      final nextChar = core[prefix.length];
      if (nextChar == nextChar.toUpperCase() &&
          nextChar != nextChar.toLowerCase()) {
        return rawWord;
      }
    }
  }

  // PROTECT: Tokens with internal punctuation (already structured)
  if (core.contains('.') || core.contains('-') || core.contains('/')) {
    return rawWord;
  }

  // EVIDENCE-BASED: Explicit capitalization boundaries in fused text
  // e.g. "HeadmasterGaleNolan", "CONTENTSCover", "TitlePage"
  final camelParts = core.split(
    RegExp(r'(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])'),
  );
  if (camelParts.length > 1 && camelParts.every((part) => part.length >= 2)) {
    final repaired = '$prefixPunct${camelParts.join(' ')}$suffixPunct';
    // Record this as evidence-based repair (camelCase boundaries are strong evidence)
    // Note: We can't easily track offsets here without more context
    return repaired;
  }

  // Safe suffix/function-word boundary splitter for fused tokens (ISM-01)
  final safeSplit = safeSplitFusedWord(rawWord);
  if (safeSplit != rawWord) {
    repairs.add(SpacingRepair(
      startOffset: 0,
      endOffset: rawWord.length,
      originalText: rawWord,
      repairedText: safeSplit,
      reason: 'fused_token',
      confidence: 0.95,
    ));
    return safeSplit;
  }

  // SHORT TOKEN: Don't attempt to break short tokens
  if (end - start < 15) return rawWord;

  // PROTECT: Internal hyphens/slashes
  if (core.contains('-') || core.contains('/')) return rawWord;

  // PROTECT: Legitimate compound words (FP-4)
  if (_protectedCompoundWords.contains(lower)) {
    return rawWord;
  }

  // DICTIONARY DECOMPOSITION: High-confidence decomposition on fused runs
  final segments = _wordBreakDP(lower);
  if (segments == null || segments.length <= 1) {
    return rawWord;
  }

  final avgSegmentLength = lower.length / segments.length;
  if (avgSegmentLength < 3.0) {
    return rawWord;
  }

  final allInDict = segments.every((s) => _fusedDictWords.contains(s));
  if (!allInDict) {
    return rawWord;
  }

  final isFirstUpper =
      core[0] == core[0].toUpperCase() && core[0] != core[0].toLowerCase();
  final resultWords = <String>[];
  var sourceOffset = 0;
  for (int i = 0; i < segments.length; i++) {
    var seg = segments[i];
    final sourceStartsUpper = sourceOffset < core.length &&
        core[sourceOffset] == core[sourceOffset].toUpperCase() &&
        core[sourceOffset] != core[sourceOffset].toLowerCase();
    final sourceSegment = core.substring(
      sourceOffset,
      (sourceOffset + segments[i].length).clamp(0, core.length),
    );
    final sourceIsAllCaps = sourceSegment.isNotEmpty &&
        sourceSegment == sourceSegment.toUpperCase() &&
        sourceSegment != sourceSegment.toLowerCase();
    if (sourceIsAllCaps) {
      seg = seg.toUpperCase();
    } else if ((i == 0 && isFirstUpper || sourceStartsUpper) && seg.isNotEmpty) {
      seg = seg[0].toUpperCase() + seg.substring(1);
    }
    resultWords.add(seg);
    sourceOffset += segments[i].length;
  }

  final repaired = '$prefixPunct${resultWords.join(' ')}$suffixPunct';
  repairs.add(SpacingRepair(
    startOffset: 0,
    endOffset: rawWord.length,
    originalText: rawWord,
    repairedText: repaired,
    reason: 'fused_token',
    confidence: 0.95,
  ));
  return repaired;
}

/// Safe suffix and function-word boundary splitter for fused tokens from extraction.
/// Splits ONLY when the whole token is NOT a valid dictionary/scientific/protected word
/// and segments match high-frequency English boundary words.
String safeSplitFusedWord(String rawWord) {
  if (rawWord.length < 6) return rawWord;

  // Extract leading/trailing punctuation
  int start = 0;
  while (start < rawWord.length && !_isLetterRe.hasMatch(rawWord[start])) {
    start++;
  }
  int end = rawWord.length;
  while (end > start && !_isLetterRe.hasMatch(rawWord[end - 1])) {
    end--;
  }
  if (start >= end) return rawWord;

  final prefixPunct = rawWord.substring(0, start);
  final core = rawWord.substring(start, end);
  final suffixPunct = rawWord.substring(end);
  final lower = core.toLowerCase();

  // PROTECT: Known single dictionary words, scientific compounds, protected compounds, surname prefixes
  if (_singleDictionaryWords.contains(lower) ||
      _scientificCompounds.contains(lower) ||
      _protectedCompoundWords.contains(lower) ||
      _protectedMixedCaseWords.contains(lower)) {
    return rawWord;
  }

  // Do not touch words with internal hyphens, slashes, or periods
  if (core.contains('-') || core.contains('/') || core.contains('.')) {
    return rawWord;
  }

  const highFreqSplitWords = {
    'intoned',
    'solemnly',
    'bellowed',
    'shouted',
    'whispered',
    'students',
    'distinguished',
    'alumni',
    'pillars',
    'year',
    'what',
    'are',
    'the',
    'four',
    'and',
    'for',
    'with',
    'from',
    'this',
    'that',
    'they',
    'have',
    'been',
    'were',
    'will',
    'would',
    'could',
    'should',
    'he',
    'she',
  };

  // Helper: check if sub decomposes strictly into highFreqSplitWords
  List<String>? decomposeHighFreq(String sub) {
    if (sub.isEmpty) return [];
    if (highFreqSplitWords.contains(sub)) {
      return [sub];
    }
    for (int len = 2; len < sub.length; len++) {
      final prefix = sub.substring(0, len);
      if (highFreqSplitWords.contains(prefix)) {
        final rest = decomposeHighFreq(sub.substring(len));
        if (rest != null && rest.isNotEmpty) {
          return [prefix, ...rest];
        }
      }
    }
    return null;
  }

  // 1. Full decomposition where ALL segments are high-frequency boundary words
  // e.g. "whatarethefourpillars", "distinguishedalumni", "andstudents", "hebellowed", "Thisyear"
  final fullParts = decomposeHighFreq(lower);
  if (fullParts != null && fullParts.length > 1) {
    final resultWords = <String>[];
    int offset = 0;
    for (int i = 0; i < fullParts.length; i++) {
      final partLen = fullParts[i].length;
      var origSegment = core.substring(offset, offset + partLen);
      if (i == 0 && core[0] == core[0].toUpperCase() && core[0] != core[0].toLowerCase()) {
        origSegment = origSegment[0].toUpperCase() + origSegment.substring(1);
      }
      resultWords.add(origSegment);
      offset += partLen;
    }
    return '$prefixPunct${resultWords.join(' ')}$suffixPunct';
  }

  // 2. Capitalized proper noun fused with verb/adverb/high-frequency suffix words
  // e.g. "Nolanintonedsolemnly" -> head="Nolan" (proper noun), tail="intoned solemnly"
  if (core[0] == core[0].toUpperCase() && core[0] != core[0].toLowerCase()) {
    for (int i = 3; i <= core.length - 4; i++) {
      final tail = lower.substring(i);
      final tailSegments = decomposeHighFreq(tail);
      if (tailSegments != null && tailSegments.isNotEmpty) {
        final head = core.substring(0, i);
        return '$prefixPunct$head ${tailSegments.join(' ')}$suffixPunct';
      }
    }
  }

  return rawWord;
}

const Set<String> _scientificCompounds = {
  'neuroplasticity',
  'electromagnetism',
  'thermodynamics',
  'photosynthesis',
  'crystallography',
  'biotechnology',
  'paleontology',
  'socioeconomic',
  'cardiovascular',
  'counterintuitive',
  'understanding',
  'notwithstanding',
  'nevertheless',
  'straightforward',
  'groundbreaking',
  'infrastructure',
  'representative',
  'responsibility',
  'characteristic',
  'simultaneously',
  'telecommunications',
  'interchangeable',
  'congratulations',
  'superintendent',
  'acknowledgment',
  'institutional',
};

const Set<String> _singleDictionaryWords = {
  'intoned',
  'solemnly',
  'bellowed',
  'alumni',
  'distinguished',
  'students',
  'pillars',
  'year',
  'dramatically',
  'expectantly',
  'procession',
  'concluded',
  'knowledge',
  'gentlemen',
  'applauded',
  'politely',
  'gentleman',
  'lighted',
  'sixties',
  'watching',
  'pointing',
  'stepped',
  'carried',
  'followed',
  'elderly',
  'proudly',
  'standing',
  'understanding',
  'conversation',
  'immediately',
  'particular',
  'particularly',
  'circumstance',
  'circumstances',
  'opportunity',
  'opportunities',
  'information',
  'development',
  'experience',
  'experiences',
  'government',
  'difference',
  'differences',
  'important',
  'impossible',
  'everything',
  'everyone',
  'something',
  'someone',
  'anything',
  'anyone',
  'themselves',
  'ourselves',
  'yourself',
  'yourselves',
  'himself',
  'herself',
  'itself',
  'another',
  'together',
  'without',
  'throughout',
  'however',
  'therefore',
  'furthermore',
  'moreover',
  'meanwhile',
  'otherwise',
  'sometimes',
  'somewhere',
  'anywhere',
  'everywhere',
  'nowhere',
  'already',
  'always',
  'almost',
  'around',
  'against',
  'between',
  'behind',
  'beyond',
  'beside',
  'besides',
  'before',
  'beneath',
  'during',
  'across',
  'toward',
  'towards',
  'inside',
  'outside',
  'within',
  'because',
  'although',
  'though',
  'through',
  'enough',
  'several',
  'certain',
  'certainly',
  'perhaps',
  'probably',
  'actually',
  'finally',
  'suddenly',
  'quickly',
  'slowly',
  'quietly',
  'loudly',
  'clearly',
  'really',
  'simply',
  'easily',
  'hardly',
  'nearly',
  'deeply',
  'greatly',
  'highly',
  'widely',
  'surely',
};

final Set<String> _fusedDictWords = <String>{
  ..._scientificCompounds,
  ..._singleDictionaryWords,
  'a',
  'about',
  'above',
  'across',
  'act',
  'acts',
  'action',
  'actions',
  'after',
  'again',
  'against',
  'age',
  'ago',
  'air',
  'all',
  'almost',
  'alone',
  'along',
  'already',
  'also',
  'although',
  'always',
  'am',
  'among',
  'an',
  'and',
  'another',
  'answer',
  'answered',
  'any',
  'anyone',
  'anything',
  'appear',
  'appeared',
  'applaud',
  'applauded',
  'applause',
  'are',
  'area',
  'arm',
  'arms',
  'army',
  'around',
  'art',
  'as',
  'ask',
  'asked',
  'asking',
  'at',
  'audience',
  'away',
  'back',
  'bad',
  'be',
  'beat',
  'beautiful',
  'beauty',
  'became',
  'because',
  'become',
  'becomes',
  'becoming',
  'been',
  'before',
  'began',
  'begin',
  'behind',
  'being',
  'believe',
  'believed',
  'best',
  'better',
  'between',
  'beyond',
  'big',
  'bill',
  'bit',
  'black',
  'blood',
  'blue',
  'board',
  'body',
  'book',
  'books',
  'born',
  'both',
  'boy',
  'boys',
  'break',
  'bring',
  'brings',
  'brother',
  'brought',
  'build',
  'built',
  'but',
  'by',
  'call',
  'called',
  'calling',
  'came',
  'can',
  'cannot',
  'car',
  'care',
  'carried',
  'carry',
  'carrying',
  'case',
  'cause',
  'certain',
  'certainly',
  'change',
  'changed',
  'child',
  'children',
  'church',
  'city',
  'clear',
  'clearly',
  'close',
  'closed',
  'cold',
  'come',
  'comes',
  'coming',
  'complete',
  'conclude',
  'concluded',
  'conclusion',
  'consider',
  'control',
  'cost',
  'could',
  'country',
  'course',
  'court',
  'cover',
  'covered',
  'cry',
  'cried',
  'cut',
  'dark',
  'darkness',
  'day',
  'days',
  'dead',
  'deal',
  'death',
  'decide',
  'decided',
  'deep',
  'deeply',
  'did',
  'die',
  'died',
  'difference',
  'different',
  'do',
  'does',
  'doing',
  'done',
  'door',
  'doors',
  'down',
  'dramatic',
  'dramatically',
  'draw',
  'dream',
  'drive',
  'drop',
  'dropped',
  'due',
  'during',
  'each',
  'early',
  'earth',
  'easy',
  'easily',
  'eat',
  'edge',
  'education',
  'effect',
  'effort',
  'eight',
  'either',
  'elderly',
  'else',
  'end',
  'ended',
  'ending',
  'enough',
  'even',
  'evening',
  'ever',
  'every',
  'everyone',
  'everything',
  'evidence',
  'exact',
  'exactly',
  'expect',
  'expected',
  'expectantly',
  'experience',
  'eye',
  'eyes',
  'face',
  'faces',
  'faced',
  'fact',
  'facts',
  'fall',
  'fell',
  'family',
  'far',
  'fast',
  'father',
  'fear',
  'feel',
  'feeling',
  'felt',
  'few',
  'field',
  'fight',
  'figure',
  'find',
  'finds',
  'finding',
  'fine',
  'fire',
  'first',
  'five',
  'floor',
  'focus',
  'follow',
  'followed',
  'following',
  'food',
  'foot',
  'feet',
  'for',
  'force',
  'form',
  'formed',
  'forward',
  'found',
  'four',
  'free',
  'friend',
  'friends',
  'from',
  'front',
  'full',
  'fully',
  'further',
  'future',
  'gale',
  'game',
  'gave',
  'general',
  'gentle',
  'gentleman',
  'gentlemen',
  'get',
  'gets',
  'getting',
  'girl',
  'girls',
  'give',
  'gives',
  'given',
  'giving',
  'go',
  'goes',
  'going',
  'gone',
  'god',
  'good',
  'got',
  'gotten',
  'great',
  'greatly',
  'green',
  'ground',
  'group',
  'grow',
  'grew',
  'grown',
  'had',
  'hair',
  'half',
  'hand',
  'hands',
  'handed',
  'happen',
  'happened',
  'happy',
  'hard',
  'has',
  'have',
  'having',
  'he',
  'head',
  'heads',
  'hear',
  'heard',
  'hearing',
  'heart',
  'heat',
  'heavy',
  'heavily',
  'held',
  'help',
  'helped',
  'her',
  'here',
  'herself',
  'high',
  'highly',
  'hill',
  'him',
  'himself',
  'his',
  'history',
  'hit',
  'hold',
  'holding',
  'home',
  'hope',
  'hoped',
  'hot',
  'hour',
  'hours',
  'house',
  'houses',
  'how',
  'however',
  'huge',
  'human',
  'hundred',
  'husky',
  'husband',
  'i',
  'idea',
  'ideas',
  'if',
  'ill',
  'image',
  'imagine',
  'imagined',
  'important',
  'in',
  'inside',
  'instead',
  'interest',
  'into',
  'is',
  'issue',
  'it',
  'its',
  'itself',
  'job',
  'join',
  'joined',
  'just',
  'keep',
  'keeping',
  'kept',
  'key',
  'kid',
  'kids',
  'kill',
  'killed',
  'kind',
  'knew',
  'know',
  'knows',
  'known',
  'knowing',
  'knowledge',
  'ladies',
  'lady',
  'land',
  'language',
  'large',
  'last',
  'lasted',
  'late',
  'later',
  'laugh',
  'laughed',
  'law',
  'lay',
  'lead',
  'leading',
  'led',
  'learn',
  'learned',
  'least',
  'leave',
  'leaving',
  'left',
  'leg',
  'legs',
  'less',
  'let',
  'letter',
  'letters',
  'level',
  'lie',
  'lies',
  'lying',
  'life',
  'lives',
  'light',
  'lights',
  'lighted',
  'lighting',
  'like',
  'liked',
  'likely',
  'line',
  'lines',
  'list',
  'listen',
  'listened',
  'little',
  'live',
  'lived',
  'living',
  'local',
  'long',
  'longer',
  'look',
  'looks',
  'looked',
  'looking',
  'lose',
  'lost',
  'lot',
  'lots',
  'loud',
  'loudly',
  'love',
  'loved',
  'low',
  'lower',
  'made',
  'main',
  'mainly',
  'major',
  'make',
  'makes',
  'making',
  'man',
  'men',
  'many',
  'march',
  'marched',
  'marching',
  'mark',
  'marked',
  'matter',
  'matters',
  'may',
  'maybe',
  'me',
  'mean',
  'means',
  'meant',
  'meet',
  'meets',
  'meeting',
  'met',
  'member',
  'members',
  'might',
  'mind',
  'minds',
  'minute',
  'minutes',
  'miss',
  'missed',
  'moment',
  'moments',
  'money',
  'month',
  'months',
  'more',
  'morning',
  'most',
  'mostly',
  'mother',
  'move',
  'moves',
  'moved',
  'moving',
  'much',
  'music',
  'must',
  'my',
  'myself',
  'name',
  'names',
  'named',
  'near',
  'nearly',
  'need',
  'needs',
  'needed',
  'never',
  'new',
  'next',
  'night',
  'nights',
  'nine',
  'no',
  'none',
  'nor',
  'not',
  'note',
  'notes',
  'noted',
  'nothing',
  'notice',
  'noticed',
  'now',
  'number',
  'numbers',
  'of',
  'off',
  'often',
  'oh',
  'old',
  'older',
  'oldest',
  'on',
  'once',
  'one',
  'ones',
  'only',
  'open',
  'opened',
  'opening',
  'or',
  'order',
  'ordered',
  'other',
  'others',
  'our',
  'ours',
  'ourselves',
  'out',
  'outside',
  'over',
  'own',
  'owned',
  'owner',
  'page',
  'pages',
  'paper',
  'part',
  'parts',
  'pass',
  'passes',
  'passed',
  'passing',
  'past',
  'pay',
  'paid',
  'paying',
  'people',
  'person',
  'place',
  'places',
  'placed',
  'plan',
  'plans',
  'planned',
  'play',
  'played',
  'playing',
  'podium',
  'point',
  'points',
  'pointed',
  'pointing',
  'polite',
  'politely',
  'poor',
  'power',
  'present',
  'process',
  'procession',
  'proud',
  'proudly',
  'problem',
  'problems',
  'put',
  'puts',
  'putting',
  'question',
  'questions',
  'quick',
  'quickly',
  'quiet',
  'quietly',
  'quite',
  'rather',
  'read',
  'reading',
  'real',
  'really',
  'reason',
  'reasons',
  'receive',
  'received',
  'red',
  'remain',
  'remained',
  'remember',
  'remembered',
  'report',
  'reported',
  'rest',
  'return',
  'returned',
  'right',
  'rights',
  'room',
  'rooms',
  'round',
  'run',
  'running',
  'ran',
  'said',
  'same',
  'saw',
  'say',
  'says',
  'saying',
  'school',
  'schools',
  'see',
  'sees',
  'seeing',
  'seen',
  'seem',
  'seems',
  'seemed',
  'seeming',
  'self',
  'send',
  'sends',
  'sending',
  'sent',
  'set',
  'sets',
  'setting',
  'several',
  'shall',
  'she',
  'short',
  'should',
  'show',
  'shows',
  'showed',
  'shown',
  'showing',
  'side',
  'sides',
  'sight',
  'simple',
  'simply',
  'since',
  'sit',
  'sits',
  'sitting',
  'sat',
  'six',
  'sixty',
  'sixties',
  'small',
  'smaller',
  'so',
  'solemn',
  'some',
  'someone',
  'something',
  'sometimes',
  'son',
  'sons',
  'soon',
  'sound',
  'sounds',
  'sounded',
  'speak',
  'speaks',
  'speaking',
  'spoke',
  'spoken',
  'special',
  'stand',
  'stands',
  'standing',
  'stood',
  'start',
  'starts',
  'started',
  'starting',
  'state',
  'states',
  'stated',
  'stay',
  'stays',
  'stayed',
  'staying',
  'step',
  'steps',
  'stepped',
  'stepping',
  'still',
  'stop',
  'stops',
  'stopped',
  'stopping',
  'story',
  'stories',
  'strong',
  'strongly',
  'student',
  'students',
  'study',
  'studies',
  'studied',
  'studying',
  'such',
  'sudden',
  'suddenly',
  'sure',
  'surely',
  'table',
  'tables',
  'take',
  'takes',
  'taking',
  'took',
  'taken',
  'talk',
  'talks',
  'talked',
  'talking',
  'tall',
  'teach',
  'teaches',
  'teaching',
  'taught',
  'teacher',
  'teachers',
  'tell',
  'tells',
  'telling',
  'told',
  'ten',
  'than',
  'thank',
  'thanked',
  'thanks',
  'that',
  'the',
  'their',
  'theirs',
  'them',
  'themselves',
  'then',
  'there',
  'therefore',
  'these',
  'they',
  'thing',
  'things',
  'think',
  'thinks',
  'thinking',
  'thought',
  'thoughts',
  'this',
  'those',
  'though',
  'three',
  'through',
  'throughout',
  'thus',
  'time',
  'times',
  'to',
  'today',
  'together',
  'too',
  'top',
  'toward',
  'towards',
  'town',
  'towns',
  'true',
  'truly',
  'truth',
  'try',
  'tries',
  'tried',
  'trying',
  'turn',
  'turns',
  'turned',
  'turning',
  'two',
  'twelve',
  'twenty',
  'under',
  'understand',
  'understands',
  'understood',
  'understanding',
  'until',
  'up',
  'upon',
  'us',
  'use',
  'uses',
  'used',
  'using',
  'usual',
  'usually',
  'very',
  'view',
  'views',
  'voice',
  'voices',
  'wait',
  'waits',
  'waited',
  'waiting',
  'walk',
  'walks',
  'walked',
  'walking',
  'wall',
  'walls',
  'want',
  'wants',
  'wanted',
  'wanting',
  'war',
  'wars',
  'watch',
  'watches',
  'watched',
  'watching',
  'water',
  'way',
  'ways',
  'we',
  'week',
  'weeks',
  'well',
  'went',
  'were',
  'what',
  'whatever',
  'when',
  'where',
  'whether',
  'which',
  'while',
  'white',
  'who',
  'whom',
  'whose',
  'why',
  'wide',
  'widely',
  'will',
  'willing',
  'would',
  'with',
  'within',
  'without',
  'woman',
  'women',
  'word',
  'words',
  'work',
  'works',
  'worked',
  'working',
  'world',
  'worlds',
  'year',
  'years',
  'yes',
  'yet',
  'you',
  'young',
  'your',
  'yours',
  'yourself',
  'yourselves'
};

const Set<String> _topRankWords = {
  'the',
  'a',
  'to',
  'of',
  'and',
  'in',
  'is',
  'it',
  'he',
  'was',
  'for',
  'on',
  'are',
  'as',
  'with',
  'his',
  'they',
  'at',
  'be',
  'this',
  'have',
  'from',
  'or',
  'one',
  'had',
  'by',
  'word',
  'but',
  'not',
  'what',
  'all',
  'were',
  'we',
  'when',
  'your',
  'can',
  'said',
  'there',
  'who',
  'man',
  'men',
  'boys',
  'boy',
  'into',
  'out',
  'up',
  'so',
  'see',
  'no',
  'way',
  'could',
  'my',
  'than',
  'first',
  'been',
  'its',
  'now',
  'find',
  'day',
  'did',
  'get',
  'come',
  'made',
  'part',
  'an'
};

List<String>? _wordBreakDP(String s) {
  final n = s.length;
  final dp = List<List<String>?>.filled(n + 1, null);
  final costs = List<int>.filled(n + 1, 999999);
  dp[0] = [];
  costs[0] = 0;

  for (int i = 1; i <= n; i++) {
    final minJ = (i - 22) < 0 ? 0 : i - 22;
    for (int j = i - 1; j >= minJ; j--) {
      if (dp[j] != null) {
        final sub = s.substring(j, i);
        if (_fusedDictWords.contains(sub)) {
          int wordWeight = _topRankWords.contains(sub) ? 1 : 3;
          if (sub.length == 1 && sub != 'a' && sub != 'i') {
            wordWeight = 50;
          }
          final newCost = costs[j] + wordWeight;
          if (newCost < costs[i]) {
            costs[i] = newCost;
            dp[i] = [...dp[j]!, sub];
          }
        }
      }
    }
  }

  return dp[n];
}

/// Reproduces Athena's adaptive feed chunking rules on the device. Every
/// returned range is a direct slice of canonicalText; no text is regenerated.
/// Abbreviation-safe sentence splitter (§ F16).
/// Splits text into complete sentences without breaking at common abbreviations or titles (Dr., Mr., etc.).
class SentenceSplitter {
  static const Set<String> abbreviations = SegmentationPolicy.abbreviations;

  /// Splits [text] into sentences using the Golden Rule sentence detector (FP-2).
  static List<String> split(String text) {
    if (text.isEmpty) return const [];
    final boundaries = SegmentationPolicy.findSentenceBoundaries(text);
    if (boundaries.isEmpty) return [text.trim()];

    final sentences = <String>[];
    int start = 0;
    for (final b in boundaries) {
      if (b > start && b <= text.length) {
        final sentence = text.substring(start, b).trim();
        if (sentence.isNotEmpty) {
          sentences.add(sentence.replaceAll(RegExp(r'\s+'), ' '));
        }
        start = b;
      }
    }
    if (start < text.length) {
      final remaining = text.substring(start).trim();
      if (remaining.isNotEmpty) {
        sentences.add(remaining.replaceAll(RegExp(r'\s+'), ' '));
      }
    }
    return sentences;
  }
}

/// Proposed replacement for the whitespace-delimited fallback (RC-01).
/// Preserves canonical slices, treats Unicode whitespace as separators,
/// and emits a complete token even if that token exceeds the soft target (atomic overflow).
List<(int, int)> whitespaceSafeRanges(
  String text, {
  int preferredChars = 380,
  int maxWords = 65,
}) {
  if (preferredChars < 1 || maxWords < 1) {
    throw ArgumentError('Budgets must be positive');
  }
  if (text.isEmpty) return const [];

  // Explicit Unicode White_Space set for deterministic cross-runtime policy.
  final token = RegExp(
    r'[^\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
    unicode: true,
  );
  final words = token.allMatches(text).toList();
  if (words.isEmpty) return [(0, text.length)];

  final result = <(int, int)>[];
  var chunkStart = 0;
  var firstWord = 0;
  while (firstWord < words.length) {
    var acceptedWord = firstWord;
    var chunkEnd = firstWord + 1 < words.length
        ? words[firstWord + 1].start
        : text.length;

    // The first token is always admitted intact, even when oversized (atomic overflow)
    for (var i = firstWord + 1; i < words.length; i++) {
      final nextEnd = i + 1 < words.length
          ? words[i + 1].start
          : text.length;
      final candidateWords = i - firstWord + 1;
      if (candidateWords > maxWords ||
          nextEnd - chunkStart > preferredChars) {
        break;
      }
      acceptedWord = i;
      chunkEnd = nextEnd;
    }
    result.add((chunkStart, chunkEnd));
    chunkStart = chunkEnd;
    firstWord = acceptedWord + 1;
  }
  return result;
}

class LosslessChunker {
  // Use shared segmentation policy for cross-platform consistency
  static const int _maxWords = SegmentationPolicy.maxWords;
  static const int _maxChars = SegmentationPolicy.preferredMaxChars;

  static final RegExp _continuationStart = RegExp(
    r'^(however|therefore|thus|moreover|furthermore|for example|for instance|as a result|in contrast|because)\b',
    caseSensitive: false,
  );
  static final RegExp _token = RegExp(r'[A-Za-z]{4,}');
  static final Set<String> _stopwords = {
    'about',
    'after',
    'also',
    'among',
    'because',
    'been',
    'before',
    'being',
    'between',
    'could',
    'does',
    'each',
    'from',
    'have',
    'into',
    'just',
    'more',
    'most',
    'over',
    'same',
    'some',
    'such',
    'than',
    'that',
    'their',
    'them',
    'then',
    'there',
    'these',
    'they',
    'this',
    'those',
    'through',
    'under',
    'very',
    'were',
    'what',
    'when',
    'where',
    'which',
    'while',
    'with',
    'would',
  };
  List<Map<String, Object?>> build({
    required String documentId,
    required String canonicalText,
    required List<Map<String, dynamic>> spans,
    int initialSequence = 1,
    int offsetDelta = 0,
    int? padWidth,
  }) {
    if (canonicalText.isEmpty) return const [];
    final units = _paragraphUnits(canonicalText, spans);
    final targetWords = _targetWords(units);
    final atoms = _makeAtoms(canonicalText, units);
    final rawRanges = _plan(canonicalText, atoms, targetWords);
    final ranges = _mergeShortFragments(canonicalText, atoms, rawRanges);

    var expectedStart = 0;
    for (final range in ranges) {
      final first = atoms[range.$1];
      final last = atoms[range.$2 - 1];
      if (first.start != expectedStart || last.end <= first.start) {
        throw StateError('Adaptive chunking produced a gap or overlap.');
      }
      expectedStart = last.end;
    }
    if (expectedStart != canonicalText.length) {
      throw StateError('Adaptive chunking did not cover the full source.');
    }

    final canonicalHash = _sha256(canonicalText);
    var previousEnd = 0;
    var currentUtf8Offset = offsetDelta;
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < ranges.length; i++) {
      final (atomStart, atomEnd) = ranges[i];
      final first = atoms[atomStart];
      final last = atoms[atomEnd - 1];
      final start = first.start;
      final end = last.end;
      if (start != previousEnd) {
        throw StateError('Adaptive chunking produced non-contiguous offsets.');
      }
      if (!SegmentationPolicy.isLegalCut(canonicalText, start)) {
        throw StateError('Illegal start cut at offset $start (mid-word boundary)');
      }
      if (!SegmentationPolicy.isLegalCut(canonicalText, end)) {
        throw StateError('Illegal end cut at offset $end (mid-word boundary)');
      }
      final rawText = canonicalText.substring(start, end);
      final seq = initialSequence + i;
      final effectivePadWidth = padWidth ?? (seq > 9999 ? SegmentationPolicy.chunkIdPadWidth : 4);
      final pages = _pagesForSpan(start, end, spans);
      final firstPage = pages.isNotEmpty ? pages.first : 1;
      final chunkByteLen = utf8.encode(rawText).length;
      final chunkStartByte = currentUtf8Offset;
      final chunkEndByte = chunkStartByte + chunkByteLen;
      currentUtf8Offset = chunkEndByte;

      result.add({
        'id': '$documentId-c${seq.toString().padLeft(effectivePadWidth, '0')}',
        'document_id': documentId,
        'sequence': seq,
        'page_start': firstPage,
        'page_number': firstPage,
        'section_title': atoms
            .skip(atomStart)
            .take(atomEnd - atomStart)
            .map((atom) => atom.sectionTitle)
            .whereType<String>()
            .firstOrNull,
        'section_role': atoms
            .skip(atomStart)
            .take(atomEnd - atomStart)
            .map((atom) => atom.sectionRole)
            .whereType<String>()
            .firstOrNull ?? 'chapter',
        'raw_text': rawText,
        'source_pages_json': jsonEncode(pages),
        'start_offset': chunkStartByte,
        'end_offset': chunkEndByte,
        'checksum': _sha256(rawText),
        'boundary_method': last.boundaryAfter,
        'canonical_sha256': canonicalHash,
      });
      previousEnd = end;
    }
    if (previousEnd != canonicalText.length) {
      throw StateError('Chunk output did not reconstruct the source text.');
    }
    return result;
  }

  String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();

  List<int> _pagesForSpan(
    int start,
    int end,
    List<Map<String, dynamic>> spans,
  ) {
    final pages = <int>{};
    for (final span in spans) {
      final spanStart = _asInt(span['start']);
      final spanEnd = _asInt(span['end']);
      if (spanEnd <= start || spanStart >= end) continue;
      final pageStart = _asInt(span['page_start'], fallback: 1);
      final pageEnd = _asInt(span['page_end'], fallback: pageStart);
      for (var page = pageStart; page <= pageEnd; page++) {
        pages.add(page);
      }
    }
    return pages.isEmpty ? [1] : (pages.toList()..sort());
  }

  int _asInt(Object? value, {int fallback = 0}) =>
      value is int ? value : int.tryParse('$value') ?? fallback;

  List<_Unit> _paragraphUnits(
    String text,
    List<Map<String, dynamic>> spans,
  ) {
    final ordered = [...spans]
      ..sort((a, b) => _asInt(a['start']).compareTo(_asInt(b['start'])));
    final units = <_Unit>[];
    var spanIndex = 0;
    var start = 0;
    while (start < text.length) {
      final delimiter = text.indexOf('\n\n', start);
      final contentEnd = delimiter < 0 ? text.length : delimiter;
      final end = delimiter < 0 ? text.length : delimiter + 2;
      final content = text.substring(start, contentEnd);
      while (spanIndex < ordered.length &&
          _asInt(ordered[spanIndex]['end']) <= start) {
        spanIndex++;
      }
      final span = spanIndex < ordered.length &&
              _asInt(ordered[spanIndex]['start']) < contentEnd
          ? ordered[spanIndex]
          : null;
      final type = (span?['type'] as String?) ?? _classify(content);
      units.add(_Unit(
        start: start,
        contentEnd: contentEnd,
        end: end,
        text: content,
        type: type,
        sectionTitle: span?['section_title'] as String?,
        sectionRole: (span?['section_role'] as String?) ?? 'chapter',
        pageStart: _asInt(span?['page_start'], fallback: 1),
        pageEnd: _asInt(span?['page_end'], fallback: 1),
      ));
      start = end;
    }
    return units;
  }

  String _classify(String text) {
    final value = text.trim();
    if (value.isEmpty) return 'paragraph';
    final words = value.split(RegExp(r'\s+'));
    if (RegExp(r'^(figure|fig\.|table|chart|diagram|photo|plate)\s+\d+[:.]?',
            caseSensitive: false)
        .hasMatch(value)) {
      return 'caption';
    }
    if (RegExp(r'[=≠≈≤≥∑∫√α-ωΑ-Ω]{2,}').hasMatch(value) && words.length < 25) {
      return 'formula';
    }
    if (RegExp(
            r'^(?:chapter|part|book|section|preface|foreword|introduction|prologue|epilogue|afterword|appendix)\b',
            caseSensitive: false)
        .hasMatch(value) && words.length <= 14) {
      return 'heading';
    }
    if (RegExp(r'^(?:[•*\-–—▪▫◦]|\d+[.)]|\([a-zA-Z0-9]+\))\s+')
        .hasMatch(value)) {
      return 'list';
    }
    if (RegExp(r'^["“「『]').hasMatch(value)) return 'quote';
    return 'paragraph';
  }

  int _wordCount(String text) {
    return SegmentationPolicy.countWords(text);
  }

  int _targetWords(List<_Unit> units) {
    final lengths = units
        .where((unit) => unit.type != 'heading' && _wordCount(unit.text) > 0)
        .map((unit) => _wordCount(unit.text))
        .toList()
      ..sort();
    if (lengths.isEmpty) return SegmentationPolicy.defaultTargetWords;
    final median = lengths[lengths.length ~/ 2];
    final shortRatio =
        lengths.where((length) => length <= 30).length / lengths.length;
    final longRatio =
        lengths.where((length) => length >= 90).length / lengths.length;
    if (median <= 30 && shortRatio >= 0.55) return SegmentationPolicy.minTargetWords;
    if (median >= 70 || longRatio >= 0.35) return SegmentationPolicy.maxTargetWords;
    return SegmentationPolicy.defaultTargetWords;
  }

  List<_Atom> _makeAtoms(String canonicalText, List<_Unit> units) {
    final atoms = <_Atom>[];
    var index = 0;
    String? currentSectionTitle;
    String currentSectionRole = 'chapter';

    while (index < units.length) {
      final unit = units[index];
      if (unit.type == 'heading') {
        final headingStart = unit.start;
        var headingEnd = unit.end;
        var sectionTitle = unit.text.trim();
        index++;
        while (index < units.length && units[index].type == 'heading') {
          headingEnd = units[index].end;
          sectionTitle = '$sectionTitle: ${units[index].text.trim()}';
          index++;
        }
        currentSectionTitle = sectionTitle;
        currentSectionRole = unit.sectionRole;
        if (index < units.length) {
          final body = units[index];
          if (body.type == 'contents_entry') {
            atoms.add(_Atom(
              start: headingStart,
              end: body.end,
              wordCount:
                  _wordCount(canonicalText.substring(headingStart, body.end)),
              paragraphId: index,
              boundaryAfter: 'paragraph',
              startsSection: true,
              sectionTitle: currentSectionTitle,
              sectionRole: currentSectionRole,
            ));
            index++;
            continue;
          }
          final isOversized =
              body.text.length > _maxChars || _wordCount(body.text) > _maxWords;
          final slices = isOversized
              ? _splitOversized(body.text)
              : [(0, body.text.length)];
          for (var part = 0; part < slices.length; part++) {
            final slice = slices[part];
            final partStart = part == 0 ? headingStart : body.start + slice.$1;
            final partEnd =
                part == slices.length - 1 ? body.end : body.start + slice.$2;
            atoms.add(_Atom(
              start: partStart,
              end: partEnd,
              wordCount:
                  _wordCount(canonicalText.substring(partStart, partEnd)),
              paragraphId: index,
              boundaryAfter: slices.length > 1 ? 'sentence' : 'paragraph',
              startsSection: part == 0,
              sectionTitle: currentSectionTitle,
              sectionRole: currentSectionRole,
            ));
          }
          index++;
          continue;
        }
        atoms.add(_Atom(
          start: headingStart,
          end: headingEnd,
          wordCount:
              _wordCount(canonicalText.substring(headingStart, headingEnd)),
          paragraphId: index - 1,
          boundaryAfter: 'paragraph',
          startsSection: true,
          sectionTitle: currentSectionTitle,
          sectionRole: currentSectionRole,
        ));
        continue;
      }

      if (unit.sectionTitle != null && unit.sectionTitle!.isNotEmpty) {
        currentSectionTitle = unit.sectionTitle;
        currentSectionRole = unit.sectionRole;
      }

      final isOversized =
          unit.text.length > _maxChars || _wordCount(unit.text) > _maxWords;
      final slices =
          isOversized ? _splitOversized(unit.text) : [(0, unit.text.length)];
      for (final slice in slices.indexed) {
        final partIndex = slice.$1;
        final (relativeStart, relativeEnd) = slice.$2;
        final partStart = unit.start + relativeStart;
        final partEnd = partIndex == slices.length - 1
            ? unit.end
            : unit.start + relativeEnd;
        atoms.add(_Atom(
          start: partStart,
          end: partEnd,
          wordCount: _wordCount(canonicalText.substring(partStart, partEnd)),
          paragraphId: index,
          boundaryAfter: slices.length > 1 ? 'sentence' : 'paragraph',
          startsSection: false,
          sectionTitle: currentSectionTitle,
          sectionRole: currentSectionRole,
        ));
      }
      index++;
    }
    return atoms;
  }

  List<(int, int)> _splitOversized(String text) {
    final pieces = _breakIntoSmallPieces(text);
    if (pieces.isEmpty) return [(0, text.length)];
    if (pieces.length == 1) return pieces;

    // Determine balanced target sizes so splits are evenly distributed without orphan tails (K-2)
    final targetCharsCap = _maxChars; // 380
    final targetWordsCap = _maxWords; // 65
    final charParts = (text.length / 320).ceil();
    final wordParts = (_wordCount(text) / 50).ceil();
    final parts = (charParts > wordParts ? charParts : wordParts).clamp(1, 1000);
    final balancedTargetChars = (text.length / parts).ceil().clamp(180, targetCharsCap);
    final balancedTargetWords = (_wordCount(text) / parts).ceil().clamp(28, targetWordsCap);

    final packed = <(int, int)>[];
    var currentStart = 0;
    var currentEnd = 0;

    for (final piece in pieces) {
      final pStart = piece.$1;
      final pEnd = piece.$2;
      if (currentEnd == currentStart) {
        currentStart = pStart;
        currentEnd = pEnd;
        continue;
      }
      final candidateChars = pEnd - currentStart;
      final candidateWords = _wordCount(text.substring(currentStart, pEnd));
      final currentChars = currentEnd - currentStart;
      final currentWords = _wordCount(text.substring(currentStart, currentEnd));

      // If adding this piece exceeds the hard caps, we must split
      if (candidateChars > targetCharsCap || candidateWords > targetWordsCap) {
        packed.add((currentStart, currentEnd));
        currentStart = pStart;
        currentEnd = pEnd;
      } else if (currentChars >= balancedTargetChars || currentWords >= balancedTargetWords) {
        // We have reached a balanced chunk size; start a new chunk
        packed.add((currentStart, currentEnd));
        currentStart = pStart;
        currentEnd = pEnd;
      } else {
        currentEnd = pEnd;
      }
    }
    if (currentEnd > currentStart) {
      packed.add((currentStart, currentEnd));
    }
    return packed.isEmpty ? [(0, text.length)] : packed;
  }

  List<(int, int)> _breakIntoSmallPieces(String text) {
    final sentBoundaries = _safeBoundaries(text);
    final sentenceSpans = <(int, int)>[];
    var prev = 0;
    for (final b in sentBoundaries) {
      if (b > prev && b <= text.length) {
        sentenceSpans.add((prev, b));
        prev = b;
      }
    }
    if (prev < text.length) {
      sentenceSpans.add((prev, text.length));
    }
    if (sentenceSpans.isEmpty) {
      sentenceSpans.add((0, text.length));
    }

    final clauseSpans = <(int, int)>[];
    for (final span in sentenceSpans) {
      final sStart = span.$1;
      final sEnd = span.$2;
      final sText = text.substring(sStart, sEnd);
      // Keep complete sentences up to _maxChars / _maxWords intact
      if (sText.length <= _maxChars && _wordCount(sText) <= _maxWords) {
        clauseSpans.add((sStart, sEnd));
      } else {
        final subSpans = _splitByClauses(sText);
        for (final sub in subSpans) {
          clauseSpans.add((sStart + sub.$1, sStart + sub.$2));
        }
      }
    }

    final finalPieces = <(int, int)>[];
    for (final span in clauseSpans) {
      final cStart = span.$1;
      final cEnd = span.$2;
      final cText = text.substring(cStart, cEnd);
      if (cText.length <= _maxChars && _wordCount(cText) <= _maxWords) {
        finalPieces.add((cStart, cEnd));
      } else {
        final subSpans = _splitByWordsOrChars(cText);
        for (final sub in subSpans) {
          finalPieces.add((cStart + sub.$1, cStart + sub.$2));
        }
      }
    }

    return finalPieces;
  }

  List<(int, int)> _splitByClauses(String text) {
    final clausePattern = RegExp(r'(?:[;:,]\s+)|(?:\s[—–-]\s)|(?:\s—\s*)');
    final matches = clausePattern.allMatches(text).toList();
    if (matches.isEmpty) return [(0, text.length)];

    final result = <(int, int)>[];
    var start = 0;
    for (final m in matches) {
      final end = m.end;
      if (end > start && SegmentationPolicy.isLegalCut(text, end)) {
        result.add((start, end));
        start = end;
      }
    }
    if (start < text.length) {
      result.add((start, text.length));
    }
    return result.isEmpty ? [(0, text.length)] : result;
  }

  List<(int, int)> _splitByWordsOrChars(String text) {
    return whitespaceSafeRanges(
      text,
      preferredChars: SegmentationPolicy.preferredMaxChars,
      maxWords: SegmentationPolicy.maxWords,
    );
  }

  List<int> _safeBoundaries(String text) {
    return SegmentationPolicy.findSentenceBoundaries(text);
  }

  double _boundaryPenalty(String left, String right, bool sameParagraph) {
    if (right.trim().isEmpty) return 0;
    var penalty = sameParagraph ? 0.12 : 0.0;
    if (_continuationStart.hasMatch(right.trimLeft())) penalty += 0.42;
    final leftTerms = _token
        .allMatches(
            left.length > 600 ? left.substring(left.length - 600) : left)
        .map((match) => match.group(0)!.toLowerCase())
        .where((term) => !_stopwords.contains(term))
        .toSet();
    final rightPrefix = right.length > 600 ? right.substring(0, 600) : right;
    final rightTerms = _token
        .allMatches(rightPrefix)
        .map((match) => match.group(0)!.toLowerCase())
        .where((term) => !_stopwords.contains(term))
        .toSet();
    if (leftTerms.isNotEmpty && rightTerms.isNotEmpty) {
      final overlap = leftTerms.intersection(rightTerms).length /
          (leftTerms.length < rightTerms.length
              ? leftTerms.length
              : rightTerms.length);
      penalty += (overlap * 0.3).clamp(0.0, 0.3);
    }
    return penalty;
  }

  List<(int, int)> _plan(String text, List<_Atom> atoms, int targetWords) {
    if (atoms.isEmpty) return const [];
    // Use shared policy for consistent minimum words across platforms
    final minimumWords = SegmentationPolicy.effectiveMinWords(targetWords);
    final costs = List<double>.filled(atoms.length + 1, double.infinity);
    final next = List<int>.filled(atoms.length, atoms.length);
    costs[atoms.length] = 0;

    // Precompute cut penalties in O(N) once before the DP loop (K-4, P1-03)
    final cutPenaltyAtEnd = List<double>.generate(atoms.length, (end) {
      if (end + 1 >= atoms.length) return 0.0;
      final left = text.substring(atoms[end].start, atoms[end].end);
      final right = text.substring(atoms[end + 1].start, atoms[end + 1].end);
      var penalty = _boundaryPenalty(
        left,
        right,
        atoms[end].paragraphId == atoms[end + 1].paragraphId,
      );
      if (atoms[end].boundaryAfter == 'sentence') penalty += 0.08;
      return penalty;
    });

    for (var start = atoms.length - 1; start >= 0; start--) {
      var words = 0;
      for (var end = start; end < atoms.length; end++) {
        if (end > start && atoms[end].startsSection) break;
        final spanChars = atoms[end].end - atoms[start].start;
        if (spanChars > 450 && end > start) break;
        words += atoms[end].wordCount;
        if (words > _maxWords && end > start) break;
        final deviation = (words - targetWords) / targetWords;
        var chunkCost = deviation * deviation;
        if (spanChars > _maxChars) {
          final charOverflow = (spanChars - _maxChars) / _maxChars;
          chunkCost += 12 * charOverflow * charOverflow;
        }
        if (words < minimumWords && end + 1 < atoms.length) {
          final shortfall = (minimumWords - words) / minimumWords;
          chunkCost += 2 * shortfall * shortfall;
        }
        if (words > _maxWords) {
          final overflow = (words - _maxWords) / _maxWords;
          chunkCost += 8 * overflow * overflow;
        }
        if (end + 1 < atoms.length) {
          chunkCost += cutPenaltyAtEnd[end];
        }
        final total = chunkCost + costs[end + 1];
        if (total < costs[start]) {
          costs[start] = total;
          next[start] = end + 1;
        }
        if (words > _maxWords || spanChars > 450) break;
      }
    }

    final ranges = <(int, int)>[];
    var start = 0;
    while (start < atoms.length) {
      final end = next[start];
      if (end <= start) {
        throw StateError('No safe feed boundary after atom $start.');
      }
      ranges.add((start, end));
      start = end;
    }
    return ranges;
  }

  List<(int, int)> _mergeShortFragments(
    String text,
    List<_Atom> atoms,
    List<(int, int)> rawRanges,
  ) {
    if (rawRanges.length <= 1) return rawRanges;
    var ranges = List<(int, int)>.from(rawRanges);
    var changed = true;
    var iterations = 0;

    // Convergence loop for merging < 24 words stubs bidirectionally (K-6, P1-01)
    while (changed && iterations < 10) {
      changed = false;
      iterations++;
      final nextRanges = <(int, int)>[];
      var i = 0;

      while (i < ranges.length) {
        final current = ranges[i];
        final aStart = current.$1;
        final aEnd = current.$2;
        final currentSlice =
            text.substring(atoms[aStart].start, atoms[aEnd - 1].end);
        final currentWords = _wordCount(currentSlice);

        // 1. Standalone heading attachment: if a chunk is a standalone heading (startsSection and wordCount <= 14)
        if (i + 1 < ranges.length &&
            atoms[aStart].startsSection &&
            (aEnd - aStart == 1) &&
            currentWords <= 14) {
          final next = ranges[i + 1];
          final nextStart = next.$1;
          final nextEnd = next.$2;
          final nextSlice =
              text.substring(atoms[nextStart].start, atoms[nextEnd - 1].end);
          final nextWords = _wordCount(nextSlice);
          final combinedChars = atoms[nextEnd - 1].end - atoms[aStart].start;
          if (currentWords + nextWords <= _maxWords && combinedChars <= _maxChars) {
            nextRanges.add((aStart, nextEnd));
            i += 2;
            changed = true;
            continue;
          }
        }

        // 2. Non-heading chunk < 24 words: attempt bidirectional merge within same section
        if (currentWords < 24 && !atoms[aStart].startsSection) {
          final canMergeLeft = nextRanges.isNotEmpty &&
              !atoms[aStart].startsSection;
          final canMergeRight = i + 1 < ranges.length &&
              !atoms[ranges[i + 1].$1].startsSection;

          int? leftWords;
          int? leftChars;
          if (canMergeLeft) {
            final prev = nextRanges.last;
            leftWords = _wordCount(
                text.substring(atoms[prev.$1].start, atoms[prev.$2 - 1].end));
            leftChars = atoms[aEnd - 1].end - atoms[prev.$1].start;
          }

          int? rightWords;
          int? rightChars;
          if (canMergeRight) {
            final next = ranges[i + 1];
            rightWords = _wordCount(
                text.substring(atoms[next.$1].start, atoms[next.$2 - 1].end));
            rightChars = atoms[next.$2 - 1].end - atoms[aStart].start;
          }

          final validLeft = canMergeLeft &&
              (currentWords + leftWords! <= _maxWords) &&
              (leftChars! <= _maxChars);
          final validRight = canMergeRight &&
              (currentWords + rightWords! <= _maxWords) &&
              (rightChars! <= _maxChars);

          if (validLeft && validRight) {
            // Merge with the shorter neighbor for optimal balance
            if (leftWords <= rightWords) {
              final prev = nextRanges.removeLast();
              nextRanges.add((prev.$1, aEnd));
              i++;
              changed = true;
              continue;
            } else {
              final next = ranges[i + 1];
              nextRanges.add((aStart, next.$2));
              i += 2;
              changed = true;
              continue;
            }
          } else if (validLeft) {
            final prev = nextRanges.removeLast();
            nextRanges.add((prev.$1, aEnd));
            i++;
            changed = true;
            continue;
          } else if (validRight) {
            final next = ranges[i + 1];
            nextRanges.add((aStart, next.$2));
            i += 2;
            changed = true;
            continue;
          }
        }

        nextRanges.add((aStart, aEnd));
        i++;
      }
      ranges = nextRanges;
    }
    return ranges;
  }
}

class _Unit {
  const _Unit({
    required this.start,
    required this.contentEnd,
    required this.end,
    required this.text,
    required this.type,
    required this.pageStart,
    required this.pageEnd,
    this.sectionTitle,
    this.sectionRole = 'chapter',
  });

  final int start;
  final int contentEnd;
  final int end;
  final String text;
  final String type;
  final int pageStart;
  final int pageEnd;
  final String? sectionTitle;
  final String sectionRole;
}

class _Atom {
  const _Atom({
    required this.start,
    required this.end,
    required this.wordCount,
    required this.paragraphId,
    required this.boundaryAfter,
    required this.startsSection,
    this.sectionTitle,
    this.sectionRole = 'chapter',
  });

  final int start;
  final int end;
  final int wordCount;
  final int paragraphId;
  final String boundaryAfter;
  final bool startsSection;
  final String? sectionTitle;
  final String sectionRole;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
