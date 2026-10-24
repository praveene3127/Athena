import 'package:crypto/crypto.dart';
import 'dart:convert';

/// Reproduces Athena's adaptive feed chunking rules on the device. Every
/// returned range is a direct slice of canonicalText; no text is regenerated.
class LosslessChunker {
  static const int _minWords = 25;
  static const int _maxWords = 90;

  static final RegExp _continuationStart = RegExp(
    r'^(however|therefore|thus|moreover|furthermore|for example|for instance|as a result|in contrast|because|but|and|so|this|these|they|it)\b',
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
  static const Set<String> _abbreviations = {
    'et al.',
    'fig.',
    'figs.',
    'e.g.',
    'i.e.',
    'dr.',
    'mr.',
    'mrs.',
    'ms.',
    'prof.',
    'vol.',
    'no.',
    'pp.',
    'vs.',
    'ca.',
    'cf.',
    'al.',
    'inc.',
    'ltd.',
    'jr.',
    'sr.',
    'approx.',
    'dept.',
    'est.',
    'min.',
    'sec.',
    'univ.',
    'ed.',
    'eds.',
    'ref.',
    'refs.',
    'eq.',
    'eqs.',
    'p.',
    'ch.',
  };
  static final RegExp _sentenceCandidate = RegExp(
    r'([.!?])(\s+)(?=[A-Z0-9"(])',
  );
  static final RegExp _word = RegExp(r'\S+');

  List<Map<String, Object?>> build({
    required String documentId,
    required String canonicalText,
    required List<Map<String, dynamic>> spans,
  }) {
    if (canonicalText.isEmpty) return const [];
    final units = _paragraphUnits(canonicalText, spans);
    final targetWords = _targetWords(units);
    final atoms = _makeAtoms(canonicalText, units);
    final ranges = _plan(canonicalText, atoms, targetWords);

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
      final rawText = canonicalText.substring(start, end);
      result.add({
        'id': '$documentId-c${(i + 1).toString().padLeft(4, '0')}',
        'document_id': documentId,
        'sequence': i + 1,
        'section_title': atoms
            .skip(atomStart)
            .take(atomEnd - atomStart)
            .map((atom) => atom.sectionTitle)
            .whereType<String>()
            .firstOrNull,
        'raw_text': rawText,
        'source_pages_json': jsonEncode(_pagesForSpan(start, end, spans)),
        'start_offset': start,
        'end_offset': end,
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
    if (words.length <= 12 &&
        !value.endsWith('.') &&
        !value.endsWith(',') &&
        !value.endsWith(';') &&
        value[0].toUpperCase() == value[0]) {
      return 'heading';
    }
    if (RegExp(r'^(?:[•*\-–—▪▫◦]|\d+[.)]|\([a-zA-Z0-9]+\))\s+')
        .hasMatch(value)) {
      return 'list';
    }
    if (RegExp(r'^["“「『]').hasMatch(value)) return 'quote';
    return 'paragraph';
  }

  int _wordCount(String text) => _word.allMatches(text).length;

  int _targetWords(List<_Unit> units) {
    final lengths = units
        .where((unit) => unit.type != 'heading' && _wordCount(unit.text) > 0)
        .map((unit) => _wordCount(unit.text))
        .toList()
      ..sort();
    if (lengths.isEmpty) return 56;
    final median = lengths[lengths.length ~/ 2];
    final shortRatio =
        lengths.where((length) => length <= 30).length / lengths.length;
    final longRatio =
        lengths.where((length) => length >= 90).length / lengths.length;
    if (median <= 30 && shortRatio >= 0.55) return 48;
    if (median >= 70 || longRatio >= 0.35) return 64;
    return 56;
  }

  List<_Atom> _makeAtoms(String canonicalText, List<_Unit> units) {
    final atoms = <_Atom>[];
    var index = 0;
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
              sectionTitle: sectionTitle,
            ));
            index++;
            continue;
          }
          final slices = _wordCount(body.text) > _maxWords
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
              sectionTitle: part == 0 ? sectionTitle : null,
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
          sectionTitle: sectionTitle,
        ));
        continue;
      }

      final slices = _wordCount(unit.text) > _maxWords
          ? _splitOversized(unit.text)
          : [(0, unit.text.length)];
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
        ));
      }
      index++;
    }
    return atoms;
  }

  List<(int, int)> _splitOversized(String text) {
    final boundaries = _safeBoundaries(text);
    if (boundaries.isEmpty) {
      return _wordCount(text) > 200 ? _hardSplit(text) : [(0, text.length)];
    }

    final pieces = <(int, int)>[];
    var previous = 0;
    for (final boundary in boundaries) {
      pieces.add((previous, boundary));
      previous = boundary;
    }
    if (previous < text.length) pieces.add((previous, text.length));

    final packed = <(int, int)>[];
    var currentStart = 0;
    var currentEnd = 0;
    for (final (partStart, partEnd) in pieces) {
      final piece = text.substring(partStart, partEnd);
      if (_wordCount(piece) > 200) {
        if (currentEnd > currentStart) packed.add((currentStart, currentEnd));
        for (final (start, end) in _hardSplit(piece)) {
          packed.add((partStart + start, partStart + end));
        }
        currentStart = partEnd;
        currentEnd = partEnd;
        continue;
      }
      final currentWords = _wordCount(text.substring(currentStart, partEnd));
      if (currentWords <= _maxWords) {
        currentEnd = partEnd;
      } else {
        if (currentEnd > currentStart) packed.add((currentStart, currentEnd));
        currentStart = partStart;
        currentEnd = partEnd;
      }
    }
    if (currentEnd > currentStart) packed.add((currentStart, currentEnd));
    return packed.isEmpty ? [(0, text.length)] : packed;
  }

  List<int> _safeBoundaries(String text) {
    final result = <int>[];
    for (final match in _sentenceCandidate.allMatches(text)) {
      final punctIndex = match.start + 1;
      final whitespaceEnd = match.end;
      if (punctIndex > 0 &&
          punctIndex + 1 < text.length &&
          _isDigit(text.codeUnitAt(punctIndex - 1)) &&
          _isDigit(text.codeUnitAt(punctIndex + 1))) {
        continue;
      }
      var tokenStart = punctIndex - 1;
      while (tokenStart > 0 && text[tokenStart - 1].trim().isNotEmpty) {
        tokenStart--;
      }
      final token = text.substring(tokenStart, punctIndex).toLowerCase();
      if (_abbreviations.contains(token)) {
        continue;
      }
      if (token.length == 2 &&
          _isLetter(token.codeUnitAt(0)) &&
          token.endsWith('.')) {
        continue;
      }
      result.add(whitespaceEnd);
    }
    return result;
  }

  bool _isDigit(int value) => value >= 48 && value <= 57;
  bool _isLetter(int value) =>
      (value >= 65 && value <= 90) || (value >= 97 && value <= 122);

  List<(int, int)> _hardSplit(String text) {
    final starts = _word.allMatches(text).map((match) => match.start).toList();
    if (starts.isEmpty) return [(0, text.length)];
    final splits = <(int, int)>[];
    var chunkStart = 0;
    for (var index = _maxWords - 1;
        index + 1 < starts.length;
        index += _maxWords) {
      final chunkEnd = starts[index + 1];
      splits.add((chunkStart, chunkEnd));
      chunkStart = chunkEnd;
    }
    if (chunkStart < text.length) splits.add((chunkStart, text.length));
    return splits;
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
    final minimumWords = (_minWords > targetWords * 0.55)
        ? _minWords
        : (targetWords * 0.55).floor();
    final costs = List<double>.filled(atoms.length + 1, double.infinity);
    final next = List<int>.filled(atoms.length, atoms.length);
    costs[atoms.length] = 0;

    for (var start = atoms.length - 1; start >= 0; start--) {
      var words = 0;
      for (var end = start; end < atoms.length; end++) {
        if (end > start && atoms[end].startsSection) break;
        words += atoms[end].wordCount;
        if (words > _maxWords && end > start) break;
        final deviation = (words - targetWords) / targetWords;
        var chunkCost = deviation * deviation;
        if (words < minimumWords && end + 1 < atoms.length) {
          final shortfall = (minimumWords - words) / minimumWords;
          chunkCost += 2 * shortfall * shortfall;
        }
        if (words > _maxWords) {
          final overflow = (words - _maxWords) / _maxWords;
          chunkCost += 8 * overflow * overflow;
        }
        if (end + 1 < atoms.length) {
          final left = text.substring(atoms[end].start, atoms[end].end);
          final right =
              text.substring(atoms[end + 1].start, atoms[end + 1].end);
          chunkCost += _boundaryPenalty(left, right,
              atoms[end].paragraphId == atoms[end + 1].paragraphId);
          if (atoms[end].boundaryAfter == 'sentence') chunkCost += 0.08;
        }
        final total = chunkCost + costs[end + 1];
        if (total < costs[start]) {
          costs[start] = total;
          next[start] = end + 1;
        }
        if (words > _maxWords) break;
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
  });

  final int start;
  final int contentEnd;
  final int end;
  final String text;
  final String type;
  final int pageStart;
  final int pageEnd;
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
  });

  final int start;
  final int end;
  final int wordCount;
  final int paragraphId;
  final String boundaryAfter;
  final bool startsSection;
  final String? sectionTitle;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
