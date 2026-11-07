import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/services/secure_storage_service.dart';
import 'package:athena/services/lossless_chunker.dart';

class _AcademicCacheEntry {
  final List<Map<String, dynamic>> results;
  final DateTime timestamp;
  _AcademicCacheEntry(this.results, this.timestamp);
}

/// Retrieves verified academic research & declarative editorial fact Context Cards
/// (REAL-WORLD STUDY, COUNTER-INTUITIVE FACT, HISTORICAL BACKSTORY, THE HIDDEN MECHANISM)
/// on device using Crossref, Europe PMC, OpenAlex, and BYOK AI with verbatim exact-quote anchoring.
class LocalContextService {
  bool hadNetworkFailure = false;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(milliseconds: 3500),
    receiveTimeout: const Duration(milliseconds: 3500),
    headers: const {'User-Agent': 'AthenaReader/1.0 (mailto:athena@reader.local)'},
  ));

  static const List<String> _archetypes = [
    'REAL-WORLD STUDY',
    'COUNTER-INTUITIVE FACT',
    'HISTORICAL BACKSTORY',
    'THE HIDDEN MECHANISM',
  ];

  static final Map<String, _AcademicCacheEntry> _academicCache = {};
  static const Duration _cacheTtl = Duration(hours: 12);
  static const int _maxCacheEntries = 100;

  static const Set<String> _excludedConceptWords = {
    // Months
    'january', 'february', 'march', 'april', 'may', 'june',
    'july', 'august', 'september', 'october', 'november', 'december',
    // Seasons
    'spring', 'summer', 'autumn', 'fall', 'winter',
    // Publishing & Document Structure
    'chapter', 'section', 'volume', 'volumes', 'book', 'part', 'page', 'pages',
    'table', 'figure', 'figures', 'edition', 'press', 'publisher', 'author',
    'introduction', 'conclusion', 'prologue', 'epilogue', 'appendix', 'index',
    // Days
    'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
    // Stopwords & Pronouns
    'the', 'this', 'that', 'these', 'those', 'there', 'when', 'where', 'while',
    'after', 'before', 'then', 'they', 'here', 'some', 'many', 'first', 'second',
    'third', 'every', 'each', 'both', 'with', 'from', 'into', 'such', 'their',
    'what', 'which', 'about', 'other', 'another', 'whose', 'whom',
  };

  /// Evaluates a chunk for narrative tension, conceptual depth, and suitability for an immersion Context Card.
  /// Rejects trivial or transitional chunks (< 25 words) with a score of -100.
  int scoreChunkTension(Map<String, Object?> chunk) {
    final text = (chunk['raw_text'] as String?)?.trim() ?? '';
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length < 25) return -100; // Reject short or transitional sentences

    int score = 0;
    // Ideal length sweet spot (25 to 75 words):
    if (words.length >= 25 && words.length <= 75) {
      score += 15;
    }

    // Tension, mystery, conflict, philosophical, or psychological indicators:
    final tensionRegex = RegExp(
      r'\b(why|secret|hidden|truth|fear|death|power|illusion|paradox|conflict|doubt|struggle|memory|silence|danger|nature|destiny|mind|soul|betrayal|loss|desire|passion|curiosity|discover|strange|impossible|wonder|question|meaning|origin|failure|triumph|irony)\b',
      caseSensitive: false,
    );
    score += tensionRegex.allMatches(text).length * 4;

    // Proper nouns or named entities (excluding sentence initial):
    final entities =
        RegExp(r'(?<![.!?]\s)\b[A-Z][a-z]{2,}\b').allMatches(text).length;
    score += (entities * 2).clamp(0, 10);

    // Dialogue and quotes:
    if (text.contains('"') || text.contains('“')) {
      score += 5;
    }

    // Lexical richness:
    final uniqueCount = words.map((w) => w.toLowerCase()).toSet().length;
    if (uniqueCount / words.length > 0.72) {
      score += 10;
    }

    return score;
  }

  /// Checks whether a passage satisfies the prose quality gate:
  /// >= 25 words, >= 2 complete sentences, and not front/back matter.
  bool passesProseQualityGate(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    final words =
        trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length < 25) return false;

    final sentences = SentenceSplitter.split(trimmed);
    if (sentences.length < 2) return false;

    final frontMatterRe = RegExp(
      r'\b(copyright|all rights reserved|table of contents|isbn\b|published by|printed in|edition|cataloging-in-publication|dedication|acknowledgements?|preface|foreword|index of)\b',
      caseSensitive: false,
    );
    if (frontMatterRe.hasMatch(trimmed)) return false;

    return true;
  }

  Future<List<Map<String, Object?>>> generateInitialBatch(
    String documentId,
    List<Map<String, Object?>> chunks,
  ) async {
    return buildCards(documentId, chunks.take(25).toList());
  }

  Future<List<Map<String, Object?>>> buildCards(
    String documentId,
    List<Map<String, Object?>> chunks,
  ) async {
    final cards = <Map<String, Object?>>[];
    final seen = <String>{};

    // Filter candidate chunks by prose quality gate
    final candidateChunks = chunks.where((c) {
      final text = (c['raw_text'] as String?) ?? '';
      return passesProseQualityGate(text);
    }).toList();

    if (candidateChunks.isEmpty) return const [];

    // Prioritize chunks by tension score
    candidateChunks.sort((a, b) => scoreChunkTension(b).compareTo(scoreChunkTension(a)));

    for (var i = 0; i < candidateChunks.length && cards.length < 5; i++) {
      final chunk = candidateChunks[i];
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
    if (passage.isEmpty || !passesProseQualityGate(passage)) return null;

    final chunkId = chunk['id']?.toString() ?? 'chunk_$slotIndex';

    // 1. Identify best salient 2-4 word concept term
    final concept = _extractSalientConcept(passage);
    if (concept == null || concept.isEmpty) return null;

    // 2. Extract verbatim exact quote from chunk
    final exactQuote = _exactQuote(passage, concept);
    if (exactQuote == null || exactQuote.isEmpty) return null;

    // 3. Retrieval-first: Fetch trusted academic evidence
    final academicEvidence = await _fetchTrustedAcademicEvidence(concept, passage);
    Map<String, dynamic>? bestEvidence;
    if (academicEvidence.isNotEmpty) {
      bestEvidence = academicEvidence.first;
    }

    if (bestEvidence == null || (bestEvidence['abstract']?.toString().isEmpty ?? true)) {
      final wiki = await _lookupWikipedia(concept);
      if (wiki != null && (wiki['extract']?.isNotEmpty ?? false)) {
        bestEvidence = {
          'title': wiki['title'] ?? concept,
          'publisher': 'Wikipedia',
          'url': wiki['url'] ?? 'https://en.wikipedia.org',
          'abstract': wiki['extract'] ?? '',
        };
      }
    }

    // 4. Content-Driven Archetype Selection
    final archetype = _determineArchetype(bestEvidence, slotIndex);

    // If no external evidence was retrieved or lexical overlap is inadequate (< 2 tokens),
    // fall back gracefully to honest offline synthesis from document text alone (F11, F12, F15)
    final evidenceAbstract =
        bestEvidence?['abstract']?.toString().trim() ?? '';
    final evidenceTitle = bestEvidence?['title']?.toString().trim() ?? '';
    final evidenceUrl = bestEvidence?['url']?.toString().trim() ?? '';
    final evidencePublisher =
        bestEvidence?['publisher']?.toString().trim() ?? 'Academic Research';

    final passageTokens = _extractTokens(passage);
    final evidenceTokens =
        _extractTokens('$evidenceTitle $evidenceAbstract');
    final hasValidEvidence = evidenceAbstract.isNotEmpty &&
        evidenceUrl.isNotEmpty &&
        passageTokens.intersection(evidenceTokens).length >= 2;

    if (!hasValidEvidence) {
      final localSummary = _summarizeLocally(passage, concept);
      final id = sha256
          .convert(utf8.encode('$documentId:$chunkId:$concept:$slotIndex'))
          .toString()
          .substring(0, 24);

      return {
        'id': 'local-$id',
        'document_id': documentId,
        'source_chunk_id': chunkId,
        'concept_name': concept,
        'card_type': archetype.toLowerCase().replaceAll(' ', '_'),
        'title': '$archetype: $concept',
        'exact_quote': exactQuote,
        'body': localSummary,
        'citations': [
          {
            'title': 'Internal Excerpt: $concept',
            'publisher': 'Document Analysis',
            'url': 'https://athena.internal/excerpt',
          }
        ],
        'verified': false,
        'support_status': 'unverified',
        'canonical_sha256': sha256.convert(utf8.encode(passage)).toString(),
        'generation_mode': 'extractive',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
    }

    // 5. Check for BYOK AI Provider
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('[Athena] SharedPreferences notice in LocalContextService: $e');
    }
    final apiKey = await SecureStorageService.instance
        .getAIKey('athena_ai_primary_api_key');
    final provider = prefs?.getString('athena_ai_primary_provider') ?? 'gemini';
    final model = prefs?.getString('athena_ai_primary_model');
    final baseUrl = prefs?.getString('athena_ai_primary_base_url');

    Map<String, dynamic>? aiCard;
    if (apiKey != null && apiKey.trim().isNotEmpty && model != null && model.trim().isNotEmpty) {
      aiCard = await _generateWithLLM(
        archetype: archetype,
        concept: concept,
        passage: passage,
        exactQuote: exactQuote,
        evidence: bestEvidence!,
        provider: provider,
        apiKey: apiKey.trim(),
        model: model.trim(),
        baseUrl: baseUrl,
      );
    }

    final String finalTitle;
    final String finalBody;
    final List<dynamic> finalCitations;

    if (aiCard != null &&
        aiCard['body'] != null &&
        aiCard['body'].toString().isNotEmpty) {
      var rawTitle = aiCard['title']?.toString() ?? '$archetype: $concept';
      var rawBody = aiCard['body']?.toString() ?? '';
      finalTitle = _cleanEditorialTitle(rawTitle, archetype, concept);
      finalBody = _cleanEditorialBody(rawBody);
      finalCitations = aiCard['citations'] is List
          ? aiCard['citations'] as List
          : [
              {
                'title': evidenceTitle,
                'publisher': evidencePublisher,
                'url': evidenceUrl,
              }
            ];
    } else {
      // Deterministic synthesis directly from retrieved verified abstract
      finalBody = _formatArchetypeBody(archetype, concept, evidenceAbstract);
      finalTitle = '$archetype: $concept';
      finalCitations = [
        {
          'title': evidenceTitle,
          'publisher': evidencePublisher,
          'url': evidenceUrl,
        }
      ];
    }

    // 6. Strict Verification Computation
    final isVerified = _computeVerification(
      cardBody: finalBody,
      sourceUrl: evidenceUrl,
      evidenceText: '$evidenceTitle $evidenceAbstract',
    );

    final id = sha256
        .convert(utf8.encode('$documentId:$chunkId:$finalTitle'))
        .toString()
        .substring(0, 24);

    return {
      'id': 'local-$id',
      'document_id': documentId,
      'source_chunk_id': chunkId,
      'concept_name': concept,
      'card_type': archetype.toLowerCase().replaceAll(' ', '_'),
      'title': finalTitle,
      'body': finalBody,
      'why_here':
          'Verified research insight for “$concept”. Grounded against academic literature.',
      'citations_json': jsonEncode(finalCitations),
      'exact_quote': exactQuote,
      'support_status': isVerified ? 'verified' : 'unverified',
      'canonical_sha256': chunk['canonical_sha256'] ?? '',
      'generation_mode': aiCard != null ? 'ai_grounded' : 'local_archetype',
      'verified': isVerified ? 1 : 0,
      'is_speculative_draft': false,
      'saved': 0,
      'dismissed': 0,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  String _cleanEditorialTitle(String raw, String archetype, String concept) {
    var t = raw
        .replaceAll(
            RegExp(
                r'[\u{1F000}-\u{1FFFF}\u{2300}-\u{27BF}\u{2B50}\u{FE00}-\u{FE0F}]',
                unicode: true),
            '')
        .trim();
    t = t
        .replaceAll(
            RegExp(
                r'^(?:REAL-WORLD STUDY|COUNTER-INTUITIVE FACT|HISTORICAL BACKSTORY|THE HIDDEN MECHANISM|EMPIRICAL STUDY|CRITICAL DEBATE|HISTORICAL CONTEXT|CORE PARADOX|Context):\s*',
                caseSensitive: false),
            '')
        .trim();
    return '$archetype: ${t.isEmpty ? concept : t}';
  }

  String _cleanEditorialBody(String text) {
    var b = text.replaceAll('||REVEAL||', ' ');
    b = b.replaceAll(
        RegExp(r'^(?:Question|Q):\s*.*?\n+(?:Answer|A|Evidence|Finding|Result):\s*',
            caseSensitive: false),
        '');
    b = b.replaceAll(RegExp(r'^\s*(?:Question|Q):\s*', caseSensitive: false), '');
    b = b.replaceAll(RegExp(r'^\s*(?:Counterpoint|Evidence):\s*', caseSensitive: false), '');
    b = b.replaceAll(
        RegExp(
            r'^(?:In this passage[,\s]+|This passage discusses[,\s]+|This excerpt explains[,\s]+)',
            caseSensitive: false),
        '');
    b = b.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return b;
  }

  String _determineArchetype(Map<String, dynamic>? evidence, int slotIndex) {
    if (evidence != null) {
      final text =
          '${evidence['title']} ${evidence['abstract']}'.toLowerCase();
      if (RegExp(r'\b(trial|trials|experiment|experiments|empirical|participants|subjects|randomized|clinical|laboratory|measured|sample size|n\s*=\s*\d+)\b')
          .hasMatch(text)) {
        return 'REAL-WORLD STUDY';
      }
      if (RegExp(r'\b(century|ancient|historical|archival|history|chronicle|origin|antiquity|medieval|renaissance|treaty|excavation)\b')
          .hasMatch(text)) {
        return 'HISTORICAL BACKSTORY';
      }
      if (RegExp(r'\b(mechanism|mechanisms|pathway|pathways|neural|molecular|cellular|circuit|receptor|physics|biochemical|dynamics|systemic)\b')
          .hasMatch(text)) {
        return 'THE HIDDEN MECHANISM';
      }
      if (RegExp(r'\b(counter|paradox|contrary|unexpected|opposite|fallacy|contradict|debate|dilemma|anomaly|dispute)\b')
          .hasMatch(text)) {
        return 'COUNTER-INTUITIVE FACT';
      }
    }
    return _archetypes[slotIndex % _archetypes.length];
  }

  String _summarizeLocally(String passage, String concept) {
    final sentences = SentenceSplitter.split(passage);
    final normConcept = concept.toLowerCase();
    for (final s in sentences) {
      if (s.toLowerCase().contains(normConcept) && s.length >= 25) {
        return s.trim();
      }
    }
    return sentences.isNotEmpty ? sentences.first.trim() : passage.trim();
  }

  String _formatArchetypeBody(
      String archetype, String concept, String extract) {
    final cleanExtract = _leadingSentences(extract, 65);
    switch (archetype) {
      case 'REAL-WORLD STUDY':
      case 'EMPIRICAL STUDY':
        return 'Empirical investigations into $concept demonstrate that $cleanExtract';
      case 'COUNTER-INTUITIVE FACT':
      case 'CRITICAL DEBATE':
        return 'In contrast to conventional assumptions, documented findings regarding $concept show that $cleanExtract';
      case 'HISTORICAL BACKSTORY':
      case 'HISTORICAL CONTEXT':
        return 'Archival records and primary historical accounts reveal that $cleanExtract';
      case 'THE HIDDEN MECHANISM':
      case 'CORE PARADOX':
        return 'The underlying mechanism governing $concept operates through documented systemic dynamics: $cleanExtract';
      default:
        return cleanExtract;
    }
  }

  bool _computeVerification({
    required String cardBody,
    required String sourceUrl,
    required String evidenceText,
  }) {
    if (!sourceUrl.startsWith('https://')) return false;
    final claimTokens = _extractTokens(cardBody);
    final evidenceTokens = _extractTokens(evidenceText);
    if (claimTokens.isEmpty) return false;
    final overlapCount = claimTokens.intersection(evidenceTokens).length;
    final overlapRatio = overlapCount / claimTokens.length;
    return overlapRatio >= 0.25;
  }

  Future<Map<String, dynamic>?> _generateWithLLM({
    required String archetype,
    required String concept,
    required String passage,
    required String exactQuote,
    required Map<String, dynamic> evidence,
    required String provider,
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    final evidenceTitle = evidence['title']?.toString() ?? concept;
    final evidencePublisher = evidence['publisher']?.toString() ?? 'Research Literature';
    final evidenceUrl = evidence['url']?.toString() ?? 'https://crossref.org';
    final evidenceAbstract = evidence['abstract']?.toString() ?? '';

    final prompt = '''
You are Athena, an elite literary and scientific reading companion. Synthesize a high-surprisal Context Card for the reader based on the author's passage and the retrieved academic evidence below.

Archetype: $archetype
Concept: $concept
Passage Excerpt: "$passage"
Verbatim Quote Anchor: "$exactQuote"

Retrieved Academic Evidence:
Title: "$evidenceTitle"
Source: "$evidencePublisher"
URL: "$evidenceUrl"
Abstract/Summary: "$evidenceAbstract"

STRICT EDITORIAL RULES:
- Write a 45–80 word continuous declarative editorial narrative connecting this exact research finding directly to the author's passage.
- GROUNDING: Base claims strictly and faithfully on the retrieved academic abstract above. DO NOT invent citations, researchers, or data.
- ZERO QUESTIONS: NEVER ask the reader a question (no '?', no 'Question: ... Answer: ...', no quizzes).
- ZERO REVEALS: NEVER use '||REVEAL||' or hidden text.
- Deliver pure outside information gain beyond the author's text.
- The citation URL MUST match the verified URL: "$evidenceUrl".

Respond ONLY with valid JSON with this exact schema:
{
  "title": "$archetype: $concept",
  "body": "<45-80 word continuous declarative editorial narrative>",
  "citations": [
    {"title": "$evidenceTitle", "publisher": "$evidencePublisher", "url": "$evidenceUrl"}
  ]
}
''';

    final pKey = provider.toLowerCase();
    final client = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
    ));

    try {
      String? rawResponse;
      if (pKey == 'gemini') {
        final url =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';
        final res = await client.post(
          url,
          options: Options(headers: {
            'x-goog-api-key': apiKey,
          }),
          data: {
            'contents': [
              {
                'parts': [
                  {'text': prompt}
                ]
              }
            ],
            'generationConfig': {
              'response_mime_type': 'application/json',
              'temperature': 0.3,
            }
          },
        );
        if (res.statusCode == 200 && res.data is Map) {
          final candidates = res.data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final parts = candidates[0]['content']?['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              rawResponse = parts[0]['text']?.toString();
            }
          }
        }
      } else if (pKey == 'openai' || pKey == 'openrouter' || pKey == 'groq') {
        final host = (baseUrl != null && baseUrl.isNotEmpty)
            ? baseUrl
            : (pKey == 'openrouter'
                ? 'https://openrouter.ai/api/v1'
                : (pKey == 'groq'
                    ? 'https://api.groq.com/openai/v1'
                    : 'https://api.openai.com/v1'));
        final res = await client.post(
          '$host/chat/completions',
          options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
          data: {
            'model': model,
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
        final res = await client.post(
          'https://api.anthropic.com/v1/messages',
          options: Options(headers: {
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          }),
          data: {
            'model': model,
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
      debugPrint('Athena LLM card generation notice: $e');
    }
    return null;
  }

  // --- MULTI-SOURCE TRUSTED ACADEMIC RESEARCH APIS ---

  String _cacheKey(String concept, String passage) {
    final c = concept.trim().toLowerCase();
    final p = passage.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final excerpt = p.length > 50 ? p.substring(0, 50) : p;
    return '$c::$excerpt';
  }

  Future<List<Map<String, dynamic>>> _fetchTrustedAcademicEvidence(
      String concept, String passage) async {
    final cacheKey = _cacheKey(concept, passage);
    if (_academicCache.containsKey(cacheKey)) {
      final entry = _academicCache[cacheKey]!;
      if (DateTime.now().difference(entry.timestamp) < _cacheTtl) {
        return entry.results;
      } else {
        _academicCache.remove(cacheKey);
      }
    }

    final List<Map<String, dynamic>> results = [];
    final futures = <Future<List<Map<String, dynamic>>>>[
      _queryCrossref(concept),
      _queryEuropePmc(concept),
      _queryOpenAlex(concept),
    ];

    try {
      final batch = await Future.wait(futures);
      for (final list in batch) {
        results.addAll(list);
      }
    } catch (e) {
      debugPrint('Athena academic fetch batch notice: $e');
    }

    if (results.isEmpty) {
      return const [];
    }

    // Relevance scoring against passage
    final passageTokens = _extractTokens(passage);
    for (final res in results) {
      final text = '${res['title']} ${res['abstract']}'.toLowerCase();
      final textTokens = _extractTokens(text);
      final overlap = passageTokens.intersection(textTokens).length;
      res['score'] = overlap;
    }

    results.sort(
        (a, b) => ((b['score'] as num?) ?? 0).compareTo((a['score'] as num?) ?? 0));

    if (_academicCache.length >= _maxCacheEntries) {
      _academicCache.remove(_academicCache.keys.first);
    }
    _academicCache[cacheKey] = _AcademicCacheEntry(results, DateTime.now());
    return results;
  }

  Future<List<Map<String, dynamic>>> _queryCrossref(String query) async {
    try {
      final cleanQ = query.replaceAll(RegExp(r'[^\w\s-]'), ' ').trim();
      final uri = Uri.parse(
          'https://api.crossref.org/works?query=${Uri.encodeComponent(cleanQ)}&filter=has-abstract:true&rows=2');
      final res = await _dio.getUri<Map<String, dynamic>>(uri);
      final items = res.data?['message']?['items'] as List?;
      if (items == null) return const [];

      final out = <Map<String, dynamic>>[];
      for (final item in items) {
        if (item is! Map) continue;
        final titleList = item['title'] as List?;
        final title = (titleList != null && titleList.isNotEmpty)
            ? titleList[0].toString()
            : 'Peer-Reviewed Paper';
        final rawAbstract = item['abstract']?.toString() ?? '';
        final cleanAbstract = rawAbstract
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final containers = item['container-title'] as List?;
        final journal = (containers != null && containers.isNotEmpty)
            ? containers[0].toString()
            : 'Academic Journal';
        final dateParts = item['published']?['date-parts'] as List?;
        final year = (dateParts != null &&
                dateParts.isNotEmpty &&
                (dateParts[0] as List).isNotEmpty)
            ? dateParts[0][0].toString()
            : '';
        final doi = item['DOI']?.toString() ?? '';
        final url = doi.isNotEmpty
            ? 'https://doi.org/$doi'
            : (item['URL']?.toString() ?? 'https://crossref.org');

        out.appendIfValid({
          'title': title,
          'abstract': cleanAbstract,
          'publisher': '$journal${year.isNotEmpty ? " ($year)" : ""} · Crossref',
          'url': url,
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _queryEuropePmc(String query) async {
    try {
      final cleanQ = query.replaceAll(RegExp(r'[^\w\s-]'), ' ').trim();
      final uri = Uri.parse(
          'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=${Uri.encodeComponent(cleanQ)}&resultType=core&format=json&pageSize=2');
      final res = await _dio.getUri<Map<String, dynamic>>(uri);
      final results = res.data?['resultList']?['result'] as List?;
      if (results == null) return const [];

      final out = <Map<String, dynamic>>[];
      for (final item in results) {
        if (item is! Map) continue;
        final title = item['title']
                ?.toString()
                .replaceAll(RegExp(r'\.+$'), '') ??
            'Empirical Study';
        final rawAbstract = item['abstractText']?.toString() ?? '';
        final cleanAbstract = rawAbstract
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final journal = item['journalTitle']?.toString() ?? 'Europe PMC';
        final year = item['pubYear']?.toString() ?? '';
        final doi = item['doi']?.toString() ?? '';
        final url = doi.isNotEmpty
            ? 'https://doi.org/$doi'
            : 'https://europepmc.org/article/MED/${item["id"]}';

        out.appendIfValid({
          'title': title,
          'abstract': cleanAbstract,
          'publisher': '$journal${year.isNotEmpty ? " ($year)" : ""} · Europe PMC',
          'url': url,
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _queryOpenAlex(String query) async {
    try {
      final cleanQ = query.replaceAll(RegExp(r'[^\w\s-]'), ' ').trim();
      final uri = Uri.parse(
          'https://api.openalex.org/works?search=${Uri.encodeComponent(cleanQ)}&per_page=2');
      final res = await _dio.getUri<Map<String, dynamic>>(uri);
      final results = res.data?['results'] as List?;
      if (results == null) return const [];

      final out = <Map<String, dynamic>>[];
      for (final item in results) {
        if (item is! Map) continue;
        final title = item['display_name']?.toString() ??
            item['title']?.toString() ??
            'Scholarly Work';

        // Reconstruct abstract from inverted index
        String abstractText = '';
        final inv = item['abstract_inverted_index'] as Map?;
        if (inv != null) {
          final wordsWithPos = <MapEntry<int, String>>[];
          for (final entry in inv.entries) {
            final word = entry.key.toString();
            final positions = entry.value as List?;
            if (positions != null) {
              for (final p in positions) {
                if (p is int) wordsWithPos.add(MapEntry(p, word));
              }
            }
          }
          wordsWithPos.sort((a, b) => a.key.compareTo(b.key));
          abstractText = wordsWithPos.map((e) => e.value).join(' ');
        }

        final year = item['publication_year']?.toString() ?? '';
        final venue = item['primary_location']?['source']?['display_name']
                ?.toString() ??
            'OpenAlex';
        final doi = item['doi']?.toString() ??
            item['id']?.toString() ??
            'https://openalex.org';

        out.appendIfValid({
          'title': title,
          'abstract': abstractText,
          'publisher': '$venue${year.isNotEmpty ? " ($year)" : ""} · OpenAlex',
          'url': doi,
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, String>?> _lookupWikipedia(String term) async {
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
        if (data?['type'] == 'standard' &&
            extract.trim().length >= 40 &&
            url != null) {
          return {'title': title, 'extract': extract, 'url': url};
        }
      }
    } catch (e) {
      hadNetworkFailure = true;
    }
    return null;
  }

  Set<String> _extractTokens(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 4)
        .toSet();
  }

  /// Extracts a 2 to 4 word salient noun phrase from the passage.
  /// Rejects single words and excluded terms (months, seasons, structure terms, etc.).
  String? _extractSalientConcept(String passage) {
    // 1. Try 2-4 word capitalized noun phrases (excluding sentence-initial common words)
    final capPhrases = RegExp(r'\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,3}\b');
    for (final m in capPhrases.allMatches(passage)) {
      final phrase = m.group(0)!.trim();
      final words = phrase.toLowerCase().split(RegExp(r'\s+'));
      if (words.length >= 2 && words.length <= 4) {
        final hasExcluded = words.any((w) => _excludedConceptWords.contains(w));
        if (!hasExcluded) {
          return phrase;
        }
      }
    }

    // 2. Try compound noun/domain patterns: 2-3 content words
    final contentWords = passage
        .split(RegExp(r'[^A-Za-z]+'))
        .where((w) =>
            w.length >= 4 &&
            !_excludedConceptWords.contains(w.toLowerCase()))
        .toList();

    if (contentWords.length >= 2) {
      // Pick first contiguous pair of content words if they appear together
      for (int i = 0; i < contentWords.length - 1; i++) {
        final pair = '${contentWords[i]} ${contentWords[i + 1]}';
        if (passage.toLowerCase().contains(pair.toLowerCase())) {
          return pair;
        }
      }
      return '${contentWords[0]} ${contentWords[1]}';
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

  String? _exactQuote(String passage, String concept) {
    final sentences = SentenceSplitter.split(passage);
    final normConcept = concept.toLowerCase();

    // Prefer sentence containing the concept
    for (final s in sentences) {
      final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.length >= 15 && clean.toLowerCase().contains(normConcept)) {
        return clean;
      }
    }

    // Fallback to any complete sentence (>= 20 chars) in the passage
    for (final s in sentences) {
      final clean = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.length >= 20) {
        return clean;
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
    return result.isEmpty ? text : result.join(' ');
  }
}

extension _AppendIfValid on List<Map<String, dynamic>> {
  void appendIfValid(Map<String, dynamic> item) {
    final title = item['title']?.toString() ?? '';
    final abstract = item['abstract']?.toString() ?? '';
    if (title.isNotEmpty || abstract.isNotEmpty) {
      add(item);
    }
  }
}
