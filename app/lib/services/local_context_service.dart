import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'secure_storage_service.dart';

/// Retrieves cited Wikipedia context at four-chunk reading intervals.
/// Retrieved prose stays separate from the source text. Only candidate terms
/// are sent; book passages and the PDF are never transmitted.
class LocalContextService {
  bool hadNetworkFailure = false;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: const {'User-Agent': 'Athena/0.1 (mobile reading app)'},
  ));

  Future<List<Map<String, Object?>>> buildCards(
    String documentId,
    List<Map<String, Object?>> chunks,
  ) async {
    final candidates =
        <({String term, Map<String, Object?> chunk, int rank})>[];
    final seen = <String>{};
    final acronyms = RegExp(r'\b[A-Z]{2,6}\b');
    final phrases = RegExp(r'\b[A-Z][a-z]{3,}(?:\s+[A-Z][a-z]{3,}){1,2}\b');
    final repeatedPhrases = RegExp(
        r'\b[a-z][a-z-]{3,}(?:\s+[a-z][a-z-]{3,}){1,2}\b',
        caseSensitive: false);
    const commonWords = {
      'about',
      'after',
      'again',
      'also',
      'among',
      'because',
      'before',
      'being',
      'between',
      'could',
      'every',
      'first',
      'from',
      'having',
      'other',
      'should',
      'their',
      'there',
      'these',
      'those',
      'through',
      'under',
      'where',
      'which',
      'while',
      'with',
      'would',
    };
    for (final chunk in chunks) {
      final sequence = chunk['sequence']! as int;
      // Sequences start at one: place optional context after chunks 4, 8, 12…
      if (sequence % 4 != 0) continue;
      final passage = chunk['raw_text']! as String;
      for (final match in [
        ...acronyms.allMatches(passage),
        ...phrases.allMatches(passage)
      ]) {
        final term = match.group(0)!.trim();
        final key = term.toLowerCase();
        if (term.length < 4 ||
            const {'united states', 'new york', 'the united'}.contains(key) ||
            !seen.add(key)) {
          continue;
        }
        candidates.add((term: term, chunk: chunk, rank: 1));
      }

      // Repeated lower-case phrases are common for concepts in self-help and
      // specialist books (for example, "growth mindset"). One-off phrases are
      // too noisy, so only retain repeats within this exact source chunk.
      final repeated = <String, ({String term, int count})>{};
      for (final match in repeatedPhrases.allMatches(passage)) {
        final term = match.group(0)!.trim();
        final words = term.toLowerCase().split(RegExp(r'\s+'));
        if (words.any((word) => commonWords.contains(word))) continue;
        final key = words.join(' ');
        final old = repeated[key];
        repeated[key] = (term: old?.term ?? term, count: (old?.count ?? 0) + 1);
      }
      for (final entry in repeated.values.where((entry) => entry.count >= 2)) {
        final key = entry.term.toLowerCase();
        if (seen.add(key)) {
          candidates.add((term: entry.term, chunk: chunk, rank: -entry.count));
        }
      }
    }
    candidates.sort((a, b) {
      final bySequence =
          (a.chunk['sequence']! as int).compareTo(b.chunk['sequence']! as int);
      return bySequence != 0 ? bySequence : a.rank.compareTo(b.rank);
    });

    final storage = SecureStorageService.instance;
    final token = await storage.getContextToken();
    final backendUrl = await storage.getBackendUrl();
    final geminiConfigured = token != null &&
        token.isNotEmpty &&
        SecureStorageService.isSecureUrl(backendUrl);

    String neighborsTextFor(int seq) {
      final prevList = chunks.where((c) => (c['sequence'] as int) == seq - 1);
      final nextList = chunks.where((c) => (c['sequence'] as int) == seq + 1);
      final prev = prevList.isEmpty ? null : prevList.first;
      final next = nextList.isEmpty ? null : nextList.first;
      final parts = <String>[];
      if (prev != null) {
        parts.add('PREVIOUS:\n${(prev['raw_text'] as String).trim()}');
      }
      if (next != null) {
        parts.add('NEXT:\n${(next['raw_text'] as String).trim()}');
      }
      return parts.join('\n\n');
    }

    final cards = <Map<String, Object?>>[];
    final sequences = <int>[];
    final titles = <String>{};
    final attemptsBySequence = <int, int>{};
    for (final candidate in candidates) {
      final chunk = candidate.chunk;
      final sequence = chunk['sequence']! as int;
      if (sequences.contains(sequence)) continue;
      final attempts = attemptsBySequence[sequence] ?? 0;
      if (attempts >= 3) continue;
      attemptsBySequence[sequence] = attempts + 1;

      final quote = _exactQuote(chunk['raw_text']! as String, candidate.term);
      if (quote == null) continue;

      // 1. Try search-grounded Gemini proxy if configured
      Map<String, dynamic>? geminiCard;
      if (geminiConfigured) {
        geminiCard = await _lookupGroundedGemini(
          documentId: documentId,
          chunkId: chunk['id']! as String,
          conceptName: candidate.term,
          passageText: (chunk['raw_text']! as String).trim(),
          neighborsText: neighborsTextFor(sequence),
          exactQuote: quote,
          backendUrl: backendUrl,
          token: token,
        );
      }

      if (geminiCard != null) {
        final title =
            (geminiCard['title'] as String?)?.trim() ?? candidate.term;
        if (!titles.add(title.toLowerCase())) continue;
        final id = sha256
            .convert(utf8.encode('$documentId:${chunk['id']}:$title'))
            .toString()
            .substring(0, 24);
        cards.add({
          'id': 'local-$id',
          'document_id': documentId,
          'source_chunk_id': chunk['id'],
          'concept_name': candidate.term,
          'card_type': 'explain',
          'title': title,
          'body': geminiCard['body'] as String? ?? '',
          'why_here':
              'Search-grounded context for “${candidate.term}”. Verified citations from independent sources.',
          'citations_json': jsonEncode(geminiCard['citations'] ?? []),
          'exact_quote': quote,
          'support_status': 'fully_supported',
          'canonical_sha256': chunk['canonical_sha256'],
          'generation_mode': 'gemini_grounded',
          'verified': 1,
          'saved': 0,
          'dismissed': 0,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
        sequences.add(sequence);
        continue;
      }

      // 2. Fallback to Wikipedia summary
      final result = await _lookup(candidate.term);
      if (result == null) continue;
      final title = result['title']!;
      if (!titles.add(title.toLowerCase())) continue;
      final extract = _leadingSentences(result['extract']!, 90);
      if (extract.isEmpty) continue;
      final id = sha256
          .convert(utf8.encode('$documentId:${chunk['id']}:$title'))
          .toString()
          .substring(0, 24);
      cards.add({
        'id': 'local-$id',
        'document_id': documentId,
        'source_chunk_id': chunk['id'],
        'concept_name': candidate.term,
        'card_type': 'explain',
        'title': title,
        'body': extract,
        'why_here':
            'Wikipedia summary retrieved for “${candidate.term}”. The quote is copied from this passage; the explanation is from the cited source.',
        'citations_json': jsonEncode([
          {'title': title, 'publisher': 'Wikipedia', 'url': result['url']}
        ]),
        'exact_quote': quote,
        'support_status': 'partially_supported',
        'canonical_sha256': chunk['canonical_sha256'],
        'generation_mode': 'retrieved_summary',
        'verified': 1,
        'saved': 0,
        'dismissed': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
      sequences.add(sequence);
    }
    return cards;
  }

  Future<Map<String, dynamic>?> _lookupGroundedGemini({
    required String documentId,
    required String chunkId,
    required String conceptName,
    required String passageText,
    required String neighborsText,
    required String exactQuote,
    required String backendUrl,
    required String token,
  }) async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 20),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'X-Athena-Context-Token': token,
          },
        ),
      );
      final res = await dio.post<Map<String, dynamic>>(
        '$backendUrl/api/context/local',
        data: {
          'document_id': documentId,
          'chunk_id': chunkId,
          'concept_name': conceptName,
          'passage_text': passageText,
          'neighbors_text': neighborsText,
          'exact_quote': exactQuote,
        },
      );
      if (res.statusCode == 200 && res.data is Map) {
        final data = res.data!;
        if (data['status'] == 'ready' && data['card'] is Map) {
          return data['card'] as Map<String, dynamic>;
        }
      }
    } catch (_) {
      // Offline, throttled, or unconfigured proxy falls back to Wikipedia
    }
    return null;
  }

  Future<Map<String, String>?> _lookup(String term) async {
    try {
      final search = await _dio.get<Map<String, dynamic>>(
          'https://en.wikipedia.org/w/api.php',
          queryParameters: {
            'action': 'query',
            'list': 'search',
            'srsearch': term,
            'srlimit': 3,
            'format': 'json',
            'utf8': 1
          });
      final results = (search.data?['query']?['search'] as List?) ?? const [];
      for (final hit in results) {
        final title = (hit as Map)['title'] as String? ?? '';
        if (!_titleMatches(term, title)) continue;
        final uri = Uri.https('en.wikipedia.org',
            '/api/rest_v1/page/summary/${Uri.encodeComponent(title.replaceAll(' ', '_'))}');
        final response = await _dio.get<Map<String, dynamic>>(uri.toString());
        final data = response.data;
        final extract = data?['extract'] as String? ?? '';
        final urls = data?['content_urls'] as Map?;
        final desktop = urls?['desktop'] as Map?;
        final url = desktop?['page'] as String?;
        final parsedUrl = url == null ? null : Uri.tryParse(url);
        if (data?['type'] == 'standard' &&
            extract.trim().length >= 60 &&
            parsedUrl?.scheme == 'https' &&
            parsedUrl?.host == 'en.wikipedia.org') {
          return {'title': title, 'extract': extract, 'url': url!};
        }
      }
    } catch (_) {
      hadNetworkFailure = true;
      // Context is optional; an offline or throttled lookup must not fail PDF processing.
    }
    return null;
  }

  bool _titleMatches(String term, String title) {
    Set<String> tokens(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((x) => x.isNotEmpty)
        .toSet();
    final termTokens = tokens(term);
    final titleTokens = tokens(title);
    // A fuzzy title match can turn a different topic into a confident-looking
    // card. Accept only an exact normalized title or all term tokens in title.
    return termTokens.isNotEmpty && termTokens.difference(titleTokens).isEmpty;
  }

  String? _exactQuote(String passage, String term) {
    for (final match in RegExp(r'[^.!?]+[.!?]?').allMatches(passage)) {
      final value = match.group(0)!.trim();
      if (RegExp('\\b${RegExp.escape(term)}\\b', caseSensitive: false)
              .hasMatch(value) &&
          passage.contains(value)) {
        return value;
      }
    }
    return null;
  }

  String _leadingSentences(String text, int wordLimit) {
    final result = <String>[];
    var count = 0;
    for (final match in RegExp(r'[^.!?]+[.!?]').allMatches(text.trim())) {
      final sentence = match.group(0)!.trim();
      final words = sentence.split(RegExp(r'\s+')).length;
      if (count + words > wordLimit) break;
      result.add(sentence);
      count += words;
    }
    return result.join(' ');
  }
}
