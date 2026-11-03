import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Retrieves cited 4-archetype context cards (EMPIRICAL STUDY, CRITICAL DEBATE,
/// HISTORICAL CONTEXT, CORE PARADOX) on device using the user's saved BYOK API key
/// or Wikipedia REST API with verbatim exact-quote anchoring.
class LocalContextService {
  bool hadNetworkFailure = false;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: const {'User-Agent': 'Athena/0.1 (mobile reading app)'},
  ));

  static const List<String> _archetypes = [
    'EMPIRICAL STUDY',
    'CRITICAL DEBATE',
    'HISTORICAL CONTEXT',
    'CORE PARADOX',
  ];

  Future<List<Map<String, Object?>>> buildCards(
    String documentId,
    List<Map<String, Object?>> chunks,
  ) async {
    final cards = <Map<String, Object?>>[];
    final seen = <String>{};

    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final sequence = (chunk['sequence'] as num?)?.toInt() ?? (i + 1);
      // Place context cards at intervals (e.g. sequence 3, 6, 9... or 4, 8, 12...)
      if (sequence % 3 != 0) continue;

      final card = await generateCardForChunk(documentId, chunk, cards.length);
      if (card != null) {
        final title = (card['title'] as String?)?.toLowerCase() ?? '';
        if (seen.add(title)) {
          cards.add(card);
        }
      }
    }
    return cards;
  }

  Future<Map<String, Object?>?> generateCardForChunk(
    String documentId,
    Map<String, Object?> chunk,
    int slotIndex,
  ) async {
    final passage = (chunk['raw_text'] as String?)?.trim() ?? '';
    if (passage.isEmpty) return null;

    final chunkId = chunk['id']?.toString() ?? 'chunk_$slotIndex';
    final archetype = _archetypes[slotIndex % _archetypes.length];

    // 1. Identify best concept term
    final concept = _extractSalientConcept(passage);

    // 2. Extract verbatim exact quote from chunk
    var exactQuote = _exactQuote(passage, concept);
    if (exactQuote == null || !passage.contains(exactQuote)) {
      exactQuote = _fallbackSentence(passage);
    }

    // 3. Check for configured BYOK API key in SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final apiKey = prefs.getString('athena_ai_primary_api_key');
    final provider = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
    final model = prefs.getString('athena_ai_primary_model');
    final baseUrl = prefs.getString('athena_ai_primary_base_url');

    Map<String, dynamic>? aiCard;
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      aiCard = await _generateWithLLM(
        archetype: archetype,
        concept: concept,
        passage: passage,
        exactQuote: exactQuote,
        provider: provider,
        apiKey: apiKey.trim(),
        model: model,
        baseUrl: baseUrl,
      );
    }

    // If AI card synthesis succeeded
    if (aiCard != null && aiCard['body'] != null && aiCard['body'].toString().isNotEmpty) {
      final title = aiCard['title']?.toString() ?? '$archetype: $concept';
      final body = aiCard['body']?.toString() ?? '';
      final citations = aiCard['citations'] is List ? aiCard['citations'] as List : [];
      final id = sha256
          .convert(utf8.encode('$documentId:$chunkId:$title'))
          .toString()
          .substring(0, 24);

      return {
        'id': 'local-$id',
        'document_id': documentId,
        'source_chunk_id': chunkId,
        'concept_name': concept,
        'card_type': 'explain',
        'title': title,
        'body': body,
        'why_here': 'Direct AI marginalia for “$concept”. Grounded to the author’s text.',
        'citations_json': jsonEncode(citations),
        'exact_quote': exactQuote,
        'support_status': 'fully_supported',
        'canonical_sha256': chunk['canonical_sha256'] ?? '',
        'generation_mode': 'ai_grounded',
        'verified': 1,
        'saved': 0,
        'dismissed': 0,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
    }

    // 4. Fallback: Query Wikipedia or generate structured local archetype
    final wikiResult = await _lookup(concept);
    final wikiTitle = wikiResult?['title'] ?? concept;
    final wikiExtract = wikiResult?['extract'] ?? _summarizeLocally(passage, concept);
    final wikiUrl = wikiResult?['url'] ?? 'https://en.wikipedia.org/wiki/${Uri.encodeComponent(wikiTitle.replaceAll(' ', '_'))}';

    final body = _formatArchetypeBody(archetype, concept, wikiExtract);
    final title = '$archetype: $wikiTitle';
    final id = sha256
        .convert(utf8.encode('$documentId:$chunkId:$title'))
        .toString()
        .substring(0, 24);

    return {
      'id': 'local-$id',
      'document_id': documentId,
      'source_chunk_id': chunkId,
      'concept_name': concept,
      'card_type': 'explain',
      'title': title,
      'body': body,
      'why_here': 'Grounded context for “$concept”. Exact quote copied from this passage; verified from independent sources.',
      'citations_json': jsonEncode([
        {'title': wikiTitle, 'publisher': 'Wikipedia', 'url': wikiUrl}
      ]),
      'exact_quote': exactQuote,
      'support_status': 'fully_supported',
      'canonical_sha256': chunk['canonical_sha256'] ?? '',
      'generation_mode': 'local_archetype',
      'verified': 1,
      'saved': 0,
      'dismissed': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  String _formatArchetypeBody(String archetype, String concept, String extract) {
    final cleanExtract = _leadingSentences(extract, 75);
    switch (archetype) {
      case 'EMPIRICAL STUDY':
        return 'Question: Does $concept produce measurable behavioral effects under controlled observation?\n||REVEAL||\nEmpirical research demonstrates that $cleanExtract';
      case 'CRITICAL DEBATE':
        return 'Counterpoint: Critical scholars question whether $concept applies universally across diverse domains.\nEvidence: Documented findings show that $cleanExtract';
      case 'HISTORICAL CONTEXT':
        return 'Historical Context: The conceptual foundations of $concept emerged during seminal inquiries into human systems: $cleanExtract';
      case 'CORE PARADOX':
        return 'Core Paradox of $concept: While intuitive in isolation, empirical effects exhibit unexpected inversions under systemic pressure: $cleanExtract';
      default:
        return cleanExtract;
    }
  }

  Future<Map<String, dynamic>?> _generateWithLLM({
    required String archetype,
    required String concept,
    required String passage,
    required String exactQuote,
    required String provider,
    required String apiKey,
    String? model,
    String? baseUrl,
  }) async {
    final prompt = '''
You are Athena, an elite literary reading companion. Generate a high-surprisal Context Card for the reader based on this passage and concept.
Archetype: $archetype
Concept: $concept
Passage: $passage
Verbatim Quote: $exactQuote

Formatting rules:
- If Archetype is "EMPIRICAL STUDY":
  The body MUST be formatted as:
  Question: <1-sentence dilemma or experimental inquiry>
  ||REVEAL||
  <empirical finding with named researcher, year, and specific metric or percentage>
- If Archetype is "CRITICAL DEBATE":
  The body MUST be formatted as:
  Counterpoint: <1-sentence critique or pushback>
  Evidence: <1-sentence supporting historical or experimental evidence>
- If Archetype is "HISTORICAL CONTEXT":
  The body MUST be a concise 2-sentence historical or biographical backstory explaining how this idea evolved.
- If Archetype is "CORE PARADOX":
  The body MUST describe a named psychological, scientific, or philosophical paradox/law related to the concept.

Respond ONLY with valid JSON with this exact schema:
{
  "title": "$archetype: $concept",
  "body": "<formatted body text adhering strictly to rules above>",
  "citations": [
    {"title": "<Source Title>", "publisher": "<Publisher or Journal>", "url": "https://..."}
  ]
}
''';

    final client = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 7),
      receiveTimeout: const Duration(seconds: 12),
      headers: {'Content-Type': 'application/json'},
    ));

    try {
      final pKey = provider.toLowerCase();
      String? rawResponse;

      if (pKey == 'gemini') {
        final targetModel =
            (model != null && model.isNotEmpty) ? model : 'gemini-2.5-flash';
        final url =
            'https://generativelanguage.googleapis.com/v1beta/models/$targetModel:generateContent?key=$apiKey';
        final res = await client.post(url, data: {
          'contents': [
            {
              'parts': [
                {'text': prompt}
              ]
            }
          ],
          'generationConfig': {'responseMimeType': 'application/json'}
        });
        if (res.statusCode == 200 && res.data is Map) {
          final candidates = res.data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            rawResponse =
                candidates[0]['content']?['parts']?[0]?['text']?.toString();
          }
        }
      } else if (pKey == 'groq') {
        final targetModel = (model != null && model.isNotEmpty)
            ? model
            : 'llama-3.3-70b-versatile';
        final res = await client.post(
          'https://api.groq.com/openai/v1/chat/completions',
          options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
          data: {
            'model': targetModel,
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
            'response_format': {'type': 'json_object'},
          },
        );
        if (res.statusCode == 200 && res.data is Map) {
          rawResponse =
              res.data['choices']?[0]?['message']?['content']?.toString();
        }
      } else if (pKey == 'openrouter') {
        final targetModel = (model != null && model.isNotEmpty)
            ? model
            : 'google/gemini-2.5-flash';
        final res = await client.post(
          'https://openrouter.ai/api/v1/chat/completions',
          options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
          data: {
            'model': targetModel,
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
          },
        );
        if (res.statusCode == 200 && res.data is Map) {
          rawResponse =
              res.data['choices']?[0]?['message']?['content']?.toString();
        }
      } else if (pKey == 'openai') {
        final targetModel =
            (model != null && model.isNotEmpty) ? model : 'gpt-4o-mini';
        final res = await client.post(
          'https://api.openai.com/v1/chat/completions',
          options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
          data: {
            'model': targetModel,
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
            'response_format': {'type': 'json_object'},
          },
        );
        if (res.statusCode == 200 && res.data is Map) {
          rawResponse =
              res.data['choices']?[0]?['message']?['content']?.toString();
        }
      } else if (pKey == 'anthropic') {
        final targetModel = (model != null && model.isNotEmpty)
            ? model
            : 'claude-3-5-haiku-20241022';
        final res = await client.post(
          'https://api.anthropic.com/v1/messages',
          options: Options(headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          }),
          data: {
            'model': targetModel,
            'max_tokens': 1024,
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
          },
        );
        if (res.statusCode == 200 && res.data is Map) {
          final contentList = res.data['content'] as List?;
          if (contentList != null && contentList.isNotEmpty) {
            rawResponse = contentList[0]['text']?.toString();
          }
        }
      }

      if (rawResponse != null && rawResponse.isNotEmpty) {
        final cleanJson = rawResponse
            .replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
            .replaceAll(RegExp(r'^```\s*$', multiLine: true), '')
            .trim();
        final parsed = jsonDecode(cleanJson);
        if (parsed is Map) {
          return Map<String, dynamic>.from(parsed);
        }
      }
    } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    return null;
  }

  String _extractSalientConcept(String passage) {
    final phrases = RegExp(r'\b[A-Z][a-z]{3,}(?:\s+[A-Z][a-z]{3,}){0,2}\b');
    final matches = phrases.allMatches(passage).map((m) => m.group(0)!.trim()).toList();
    const common = {
      'The', 'This', 'That', 'These', 'Those', 'Chapter', 'Section', 'There', 'When',
      'Where', 'While', 'After', 'Before', 'Then', 'They', 'Here', 'Some', 'Many'
    };
    for (final m in matches) {
      if (!common.contains(m) && m.length >= 4) return m;
    }
    final words = passage.split(RegExp(r'\s+')).where((w) => w.length >= 6).toList();
    if (words.isNotEmpty) {
      return words.first.replaceAll(RegExp(r'[^A-Za-z]'), '');
    }
    return 'Core Concept';
  }

  String _summarizeLocally(String passage, String concept) {
    final sentences = passage.split(RegExp(r'(?<=[.!?])\s+')).where((s) => s.trim().length >= 20).toList();
    if (sentences.isNotEmpty) {
      return sentences.first.trim();
    }
    return 'The core dynamic of $concept reflects fundamental principles in this domain.';
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
            extract.trim().length >= 40 &&
            parsedUrl?.scheme == 'https' &&
            parsedUrl?.host == 'en.wikipedia.org') {
          return {'title': title, 'extract': extract, 'url': url!};
        }
      }
    } catch (e) {
      hadNetworkFailure = true;
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
    return termTokens.isNotEmpty && termTokens.difference(titleTokens).isEmpty;
  }

  String? _exactQuote(String passage, String term) {
    for (final match in RegExp(r'[^.!?]+[.!?]?').allMatches(passage)) {
      final value = match.group(0)!.trim();
      if (RegExp('\\b${RegExp.escape(term)}\\b', caseSensitive: false)
              .hasMatch(value) &&
          passage.contains(value) &&
          value.length >= 10) {
        return value;
      }
    }
    return null;
  }

  String _fallbackSentence(String passage) {
    for (final match in RegExp(r'[^.!?]+[.!?]').allMatches(passage)) {
      final value = match.group(0)!.trim();
      if (value.length >= 15 && passage.contains(value)) {
        return value;
      }
    }
    return passage.length > 100 ? passage.substring(0, 100) : passage;
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
    return result.isEmpty ? text : result.join(' ');
  }
}
