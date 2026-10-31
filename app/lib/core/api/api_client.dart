import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:athena/core/config/config.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/lossless_chunker.dart';

class ApiClient {
  final Dio dio;

  ApiClient({Dio? client})
      : dio = client ??
            Dio(
              BaseOptions(
                baseUrl: AppConfig.apiBaseUrl,
                connectTimeout: const Duration(seconds: 6),
                receiveTimeout: const Duration(seconds: 45),
                headers: {'Accept': 'application/json'},
              ),
            ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          // Re-read every request so Settings → Server URL and web origin
          // (LAN IP / tunnel / :8000) take effect without recreating Dio.
          var base = AppConfig.apiBaseUrl;
          if (kIsWeb) {
            try {
              final origin = Uri.base.origin;
              final host = Uri.base.host.toLowerCase();
              if (origin.isNotEmpty &&
                  origin != 'null' &&
                  host != 'localhost' &&
                  host != '127.0.0.1') {
                base = origin;
              }
            } catch (_) {}
          }
          if (base.isNotEmpty) {
            options.baseUrl = base;
          }
          return handler.next(options);
        },
      ),
    );
  }

  // --- Health ---

  Future<Map<String, dynamic>> checkHealth() async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return {'status': 'ok', 'mode': 'on_device_standalone'};
    }
    try {
      final response = await dio.get('/api/health');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Map<String, dynamic>?> checkAppUpdate({
    String? currentVersion,
    String? platform,
  }) async {
    if (AppConfig.apiBaseUrl.isEmpty) return null;
    try {
      final response = await dio.get(
        '/api/app-update',
        queryParameters: {
          if (currentVersion != null) 'current_version': currentVersion,
          if (platform != null) 'platform': platform,
        },
      );
      return response.data as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // --- Documents ---

  Future<List<Map<String, dynamic>>> listDocuments() async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return await LocalDatabase.instance.listDocuments();
    }
    try {
      final response = await dio.get('/api/documents');
      final list = (response.data as List).cast<Map<String, dynamic>>();
      _cacheDocumentsLocally(list);
      return list;
    } on DioException catch (e) {
      final cached = await _loadCachedDocuments();
      if (cached.isNotEmpty) return cached;
      throw _handleDioError(e);
    } catch (_) {
      final cached = await _loadCachedDocuments();
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> getDocument(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      final doc = await LocalDatabase.instance.getDocument(id);
      if (doc == null) {
        throw const AppError(code: 'NOT_FOUND', message: 'Document not found');
      }
      return doc;
    }
    try {
      final response = await dio.get('/api/documents/$id');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Map<String, dynamic>> getDocumentStatus(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      final doc = await LocalDatabase.instance.getDocument(id);
      if (doc == null) {
        throw const AppError(code: 'NOT_FOUND', message: 'Document not found');
      }
      return {
        'document_id': id,
        'status': doc['status'] ?? 'ready',
        'stage': doc['stage'] ?? 'done',
        'stage_label': doc['stage_label'] ?? 'Ready to read',
        'percent': doc['percent'] ?? 100,
      };
    }
    try {
      final response = await dio.get('/api/documents/$id/status');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<String> uploadDocument(
    Stream<List<int>> fileStream,
    int fileSize,
    String fileName, {
    void Function(int, int)? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      final lowerName = fileName.toLowerCase();
      if (lowerName.endsWith('.pdf') || lowerName.endsWith('.epub')) {
        throw const AppError(
          code: 'BACKEND_DISCONNECTED',
          message:
              'Athena Backend connection required to process PDF/EPUB books losslessly. Please set your Backend URL in Settings.',
        );
      }
      final docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
      final bytes = <int>[];
      await for (final chunk in fileStream) {
        bytes.addAll(chunk);
      }
      String canonicalText;
      try {
        canonicalText = utf8.decode(bytes);
      } catch (_) {
        canonicalText = String.fromCharCodes(bytes);
      }
      if (canonicalText.trim().isEmpty) {
        canonicalText = 'Document: $fileName\n\nPreserved text content.';
      }

      final now = DateTime.now().toIso8601String();
      await LocalDatabase.instance.insertDocument({
        'id': docId,
        'filename': fileName,
        'title': fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
        'status': 'ready',
        'stage': 'done',
        'stage_label': 'Ready to read',
        'percent': 100,
        'page_count': 1,
        'processed_page': 1,
        'file_path': 'local://$fileName',
        'canonical_text': canonicalText,
        'integrity_verified': 1,
        'context_status': 'ready',
        'created_at': now,
        'updated_at': now,
      });

      final chunkMaps = LosslessChunker().build(
        documentId: docId,
        canonicalText: canonicalText,
        spans: [
          {
            'start': 0,
            'end': canonicalText.length,
            'page_start': 1,
            'page_end': 1,
            'type': 'paragraph',
          },
        ],
      );

      await LocalDatabase.instance.insertChunks(chunkMaps);

      try {
        final contextService = LocalContextService();
        final cards = await contextService.buildCards(docId, chunkMaps);
        final cardMaps = cards
            .map((cd) => {
                  'id': cd['id'] ?? 'card_${cd['concept_name']}',
                  'document_id': docId,
                  'source_chunk_id':
                      cd['source_chunk_id'] ?? chunkMaps.first['id']!,
                  'concept_name': cd['concept_name'] ?? '',
                  'card_type': cd['card_type'] ?? 'context',
                  'title': cd['title'] ?? '',
                  'body': cd['body'] ?? '',
                  'why_here': cd['why_here'] ?? '',
                  'citations_json': cd['citations_json'] ?? '[]',
                  'exact_quote': cd['exact_quote'],
                  'support_status': 'fully_supported',
                  'canonical_sha256': cd['canonical_sha256'] ?? '',
                  'generation_mode': 'extractive',
                  'verified': 1,
                  'saved': 0,
                  'dismissed': 0,
                  'created_at': now,
                })
            .toList();
        await LocalDatabase.instance.insertCards(cardMaps);
      } catch (_) {}

      return docId;
    }

    try {
      final formData = FormData.fromMap({
        'file': MultipartFile.fromStream(
          () => fileStream,
          fileSize,
          filename: fileName,
        ),
      });
      final response = await dio.post(
        '/api/documents/upload',
        data: formData,
        options: Options(receiveTimeout: const Duration(minutes: 5)),
        onSendProgress: onSendProgress,
        cancelToken: cancelToken,
      );
      return (response.data as Map<String, dynamic>)['document_id'] as String;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        throw const AppError(code: 'CANCELLED', message: 'Upload cancelled');
      }
      throw _handleDioError(e);
    }
  }

  Future<String> loadSampleDocument() async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      final docId = 'sample_${DateTime.now().millisecondsSinceEpoch}';
      const sampleText = 'Chapter 7: Cellular Metabolism\n\n'
          'Introduction to Cellular Respiration\n'
          'Cellular respiration is a set of metabolic reactions and processes that take place in the cells of organisms to convert chemical energy from nutrients into adenosine triphosphate (ATP), and then release waste products. The catabolic reactions involved in respiration include glycolysis, the citric acid cycle, and oxidative phosphorylation.\n\n'
          'Glycolysis is a metabolic pathway that converts glucose into pyruvate. The free energy released in this process is used to form the high-energy molecules ATP and reduced nicotinamide adenine dinucleotide (NADH). Glycolysis is a sequence of ten enzyme-catalyzed reactions. Most monosaccharides, such as fructose and galactose, can be converted to one of these intermediates.\n\n'
          'The Role of Mitochondria\n'
          'A mitochondrion is a membrane-bound organelle found in the cytoplasm of eukaryotic organisms that is responsible for creating most of the cell supply of chemical energy through aerobic respiration. Mitochondria are often described as the powerhouses of the cell. They generate most of the chemical energy needed to power the biochemical reactions of the cell.\n\n'
          'Chemical energy produced by the mitochondria is stored in a small molecule called adenosine triphosphate (ATP). Mitochondria contain their own small chromosome and DNA. Mitochondria are generally thought to have evolved through endosymbiosis when an ancestral eukaryote engulfed a symbiotic bacterium.\n\n'
          'Photosynthesis in Plant Biology\n'
          'Photosynthesis is a biological process utilized by plants and other photosynthetic organisms to convert light energy into chemical energy. This energy is stored in carbohydrate molecules, such as sugars and starches, which are synthesized from carbon dioxide and water.\n\n'
          'Chloroplasts are plant cell organelles that conduct photosynthesis. Chloroplasts absorb sunlight and use it in conjunction with water and carbon dioxide gas to produce food for the plant. Chloroplasts are distinguished from other types of plastids by their green color, which results from the presence of two pigment molecules called chlorophyll a and chlorophyll b.';

      final now = DateTime.now().toIso8601String();
      await LocalDatabase.instance.insertDocument({
        'id': docId,
        'filename': 'sample_biology.txt',
        'title': 'Chapter 7: Cellular Metabolism',
        'status': 'ready',
        'stage': 'done',
        'stage_label': 'Ready to read',
        'percent': 100,
        'page_count': 3,
        'processed_page': 3,
        'file_path': 'local://sample',
        'canonical_text': sampleText,
        'integrity_verified': 1,
        'context_status': 'ready',
        'created_at': now,
        'updated_at': now,
      });

      final chunkMaps = LosslessChunker().build(
        documentId: docId,
        canonicalText: sampleText,
        spans: [
          {
            'start': 0,
            'end': sampleText.length,
            'page_start': 1,
            'page_end': 3,
            'type': 'paragraph',
          },
        ],
      );

      await LocalDatabase.instance.insertChunks(chunkMaps);

      try {
        final contextService = LocalContextService();
        final cards = await contextService.buildCards(docId, chunkMaps);
        final cardMaps = cards
            .map((cd) => {
                  'id': cd['id'] ?? 'card_${cd['concept_name']}',
                  'document_id': docId,
                  'source_chunk_id':
                      cd['source_chunk_id'] ?? chunkMaps.first['id']!,
                  'concept_name': cd['concept_name'] ?? '',
                  'card_type': cd['card_type'] ?? 'context',
                  'title': cd['title'] ?? '',
                  'body': cd['body'] ?? '',
                  'why_here': cd['why_here'] ?? '',
                  'citations_json': cd['citations_json'] ?? '[]',
                  'exact_quote': cd['exact_quote'],
                  'support_status': 'fully_supported',
                  'canonical_sha256': cd['canonical_sha256'] ?? '',
                  'generation_mode': 'extractive',
                  'verified': 1,
                  'saved': 0,
                  'dismissed': 0,
                  'created_at': now,
                })
            .toList();
        await LocalDatabase.instance.insertCards(cardMaps);
      } catch (_) {}

      return docId;
    }

    try {
      final response = await dio.post('/api/documents/sample');
      return (response.data as Map<String, dynamic>)['document_id'] as String;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> retryDocument(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) return;
    try {
      await dio.post('/api/documents/$id/process');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> forceIngestDocument(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) return;
    try {
      await dio.post('/api/documents/$id/force-ingest');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> deleteDocument(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      await LocalDatabase.instance.deleteDocument(id);
      return;
    }
    try {
      await dio.delete('/api/documents/$id');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  // --- Reader ---

  Future<Map<String, dynamic>> getReader(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return await LocalDatabase.instance.getReaderData(id);
    }
    try {
      final response = await dio.get('/api/documents/$id/reader');
      final data = response.data as Map<String, dynamic>;
      _cacheReaderLocally(id, data);
      return data;
    } on DioException catch (e) {
      final cached = await _loadCachedReader(id);
      if (cached != null && cached.isNotEmpty) return cached;
      throw _handleDioError(e);
    } catch (_) {
      final cached = await _loadCachedReader(id);
      if (cached != null && cached.isNotEmpty) return cached;
      rethrow;
    }
  }

  Future<String> uploadDocumentFromUrl(String url) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      throw const AppError(
        code: 'NETWORK_REQUIRED',
        message:
            'Importing via URL requires a connection to the Athena server.',
      );
    }
    try {
      final response = await dio.post(
        '/api/documents/upload-url',
        data: {'url': url},
      );
      return (response.data as Map<String, dynamic>)['document_id'] as String;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<List<Map<String, dynamic>>> searchDocument(
    String docId,
    String query, {
    int topK = 8,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.get(
          '/api/documents/$docId/search',
          queryParameters: {'q': trimmed, 'top_k': topK},
        );
        if (response.data is Map &&
            (response.data as Map).containsKey('results')) {
          return List<Map<String, dynamic>>.from(
              response.data['results'] as List);
        } else if (response.data is List) {
          return List<Map<String, dynamic>>.from(response.data as List);
        }
      } catch (_) {}
    }

    // Local substring search fallback over cached chunks if offline
    final cached = await _loadCachedReader(docId);
    final results = <Map<String, dynamic>>[];
    if (cached != null && cached['chunks'] is List) {
      final qLower = trimmed.toLowerCase();
      final chunks = cached['chunks'] as List;
      for (int i = 0; i < chunks.length; i++) {
        final c = chunks[i];
        if (c is! Map) continue;
        final text = (c['text'] ?? c['raw_text'] ?? '').toString();
        if (text.toLowerCase().contains(qLower)) {
          results.add({
            'chunk_id': c['id']?.toString() ?? '',
            'sequence': c['sequence'] ?? i,
            'section_title': c['section_title'] ?? '',
            'raw_text': text,
            'rrf_score': 1.0,
          });
          if (results.length >= topK) break;
        }
      }
    }
    return results;
  }

  Future<void> _cacheDocumentsLocally(List<Map<String, dynamic>> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_documents_list', jsonEncode(list));
      if (!kIsWeb) {
        for (final doc in list) {
          final docId = doc['id']?.toString();
          if (docId == null) continue;
          await LocalDatabase.instance.insertDocument({
            'id': docId,
            'filename': doc['filename']?.toString() ?? 'document.pdf',
            'title': doc['title']?.toString() ?? 'Untitled Document',
            'status': doc['status']?.toString() ?? 'ready',
            'stage': doc['stage']?.toString() ?? 'done',
            'stage_label': doc['stage_label']?.toString() ?? 'Ready to read',
            'percent': (doc['percent'] as num?)?.toInt() ?? 100,
            'page_count': (doc['page_count'] as num?)?.toInt() ?? 0,
            'processed_page': (doc['page_count'] as num?)?.toInt() ?? 0,
            'file_path': 'cached://$docId',
            'created_at': doc['created_at']?.toString() ??
                DateTime.now().toIso8601String(),
            'updated_at': doc['updated_at']?.toString() ??
                DateTime.now().toIso8601String(),
          });
        }
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _loadCachedDocuments() async {
    try {
      if (!kIsWeb) {
        final dbDocs = await LocalDatabase.instance.listDocuments();
        if (dbDocs.isNotEmpty) return dbDocs;
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cached_documents_list');
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List;
        return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _cacheReaderLocally(
      String docId, Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('reader_cache_$docId', jsonEncode(data));
      if (!kIsWeb) {
        final rawChunks = data['chunks'] as List?;
        final rawCards = data['cards'] as List?;
        if (rawChunks != null) {
          final chunkMaps = rawChunks.map((c) {
            final map = Map<String, dynamic>.from(c as Map);
            final seq = (map['sequence'] as num?)?.toInt() ?? 1;
            return <String, Object?>{
              'id': map['id']?.toString() ?? 'chunk_${docId}_$seq',
              'document_id': docId,
              'sequence': seq,
              'section_title': map['section_title']?.toString(),
              'raw_text':
                  map['raw_text']?.toString() ?? map['text']?.toString() ?? '',
              'source_pages_json': jsonEncode(map['source_pages'] ?? [1]),
              'start_offset': (map['start_offset'] as num?)?.toInt() ?? 0,
              'end_offset': (map['end_offset'] as num?)?.toInt() ?? 0,
              'checksum': map['checksum']?.toString() ?? '',
              'boundary_method': 'sentence',
              'canonical_sha256': map['canonical_sha256']?.toString() ?? '',
            };
          }).toList();
          await LocalDatabase.instance.insertChunks(chunkMaps);
        }
        if (rawCards != null) {
          final cardMaps = rawCards.map((cd) {
            final map = Map<String, dynamic>.from(cd as Map);
            final cId = map['id']?.toString() ?? 'card_${map['concept_name']}';
            return <String, Object?>{
              'id': cId,
              'document_id': docId,
              'source_chunk_id': map['source_chunk_id']?.toString() ?? '',
              'concept_name': map['concept_name']?.toString() ?? '',
              'card_type': map['card_type']?.toString() ?? 'context',
              'title': map['title']?.toString() ?? '',
              'body': map['body']?.toString() ?? '',
              'why_here': map['why_here']?.toString() ?? '',
              'citations_json': map['citations_json']?.toString() ??
                  jsonEncode(map['citations'] ?? []),
              'exact_quote': map['exact_quote']?.toString(),
              'support_status': 'fully_supported',
              'canonical_sha256': map['canonical_sha256']?.toString() ?? '',
              'generation_mode': 'grounded',
              'verified': 1,
              'saved': (map['saved'] == true || map['saved'] == 1) ? 1 : 0,
              'dismissed':
                  (map['dismissed'] == true || map['dismissed'] == 1) ? 1 : 0,
              'created_at': map['created_at']?.toString() ??
                  DateTime.now().toIso8601String(),
            };
          }).toList();
          await LocalDatabase.instance.insertCards(cardMaps);
        }
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _loadCachedReader(String docId) async {
    try {
      if (!kIsWeb) {
        final dbData = await LocalDatabase.instance.getReaderData(docId);
        final chunks = dbData['chunks'] as List?;
        if (chunks != null && chunks.isNotEmpty) {
          return dbData;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('reader_cache_$docId');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> syncReadingProgress(String id, int chunkIndex,
      {String readingMode = 'feed'}) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return {'status': 'saved', 'chunk_index': chunkIndex};
    }
    try {
      final response = await dio.post(
        '/api/documents/$id/progress',
        data: {'chunk_index': chunkIndex, 'reading_mode': readingMode},
      );
      if (response.data is Map<String, dynamic>) {
        return response.data as Map<String, dynamic>;
      }
      return {};
    } catch (_) {
      // Best-effort background progress sync; ignore offline drops
      return {};
    }
  }

  Future<List<Map<String, dynamic>>> getChapters(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return [];
    }
    try {
      final response = await dio.get('/api/documents/$id/chapters');
      return (response.data as List).cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  String getMarkdownExportUrl(String id) {
    return '${AppConfig.apiBaseUrl}/api/documents/$id/export-markdown';
  }

  String pageImageUrl(String docId, int pageNumber) {
    return '${AppConfig.apiBaseUrl}/api/documents/$docId/pages/$pageNumber/image';
  }

  Future<String?> localPdfPath(String documentId) async => null;

  Future<Map<String, dynamic>> fetchVibeCheck(
      String docId, int chunkIndex) async {
    try {
      final response = await dio.post(
        '/api/documents/$docId/vibe-check',
        data: {'chunk_index': chunkIndex},
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  // --- Cards & Saved (Phase 5) ---

  Future<void> saveCard(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      await LocalDatabase.instance.setCardSaved(id, true);
      return;
    }
    try {
      await dio.post('/api/cards/$id/save');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> unsaveCard(String id) async {
    // 1. Remove from local SharedPreferences notes cache
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'athena_saved_notes_v1',
        'athena_brain_deck_cards_v1',
        'athena_brain_deck_v1'
      ]) {
        final raw = prefs.getString(key);
        if (raw != null && raw.isNotEmpty) {
          final decoded = json.decode(raw);
          if (decoded is List) {
            final filtered = decoded
                .where((item) => item is Map && item['id']?.toString() != id)
                .toList();
            await prefs.setString(key, json.encode(filtered));
          }
        }
      }
    } catch (_) {}

    // 2. Remove from LocalDatabase
    try {
      await LocalDatabase.instance.setCardSaved(id, false);
    } catch (_) {}

    // 3. Remove from remote backend if connected
    if (AppConfig.apiBaseUrl.isEmpty) {
      return;
    }
    try {
      await dio.delete('/api/cards/$id/save');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> clearAllSavedCards() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('athena_saved_notes_v1');
      await prefs.remove('athena_brain_deck_cards_v1');
      await prefs.remove('athena_brain_deck_v1');
    } catch (_) {}
    try {
      final db = await LocalDatabase.instance.database;
      await db.update('context_cards', {'saved': 0});
    } catch (_) {}
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final list = await getSavedCards();
        for (final item in list) {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            await dio.delete('/api/cards/$id/save');
          }
        }
      } catch (_) {}
    }
  }

  Future<void> dismissCard(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      await LocalDatabase.instance.setCardDismissed(id, true);
      return;
    }
    try {
      await dio.post('/api/cards/$id/dismiss');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<void> restoreCard(String id) async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      await LocalDatabase.instance.setCardDismissed(id, false);
      return;
    }
    try {
      await dio.post('/api/cards/$id/restore');
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<List<Map<String, dynamic>>> getSavedCards() async {
    if (AppConfig.apiBaseUrl.isEmpty) {
      return await LocalDatabase.instance.getSavedCards();
    }
    try {
      final response = await dio.get('/api/saved');
      return (response.data as List).cast<Map<String, dynamic>>();
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  // --- Ask (Phase 6) ---

  Future<Map<String, dynamic>> askAboutPassage({
    required String documentId,
    required String chunkId,
    required String question,
    String? selectedText,
  }) async {
    try {
      final response = await dio.post(
        '/api/ask',
        data: {
          'document_id': documentId,
          'chunk_id': chunkId,
          'question': question,
          if (selectedText != null) 'selected_text': selectedText,
        },
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  // --- BYOK Multi-Provider AI Settings ---

  Future<AIConfig> getAIConfig() async {
    try {
      final response = await dio.get('/api/settings/ai-config');
      return AIConfig.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Map<String, dynamic>> saveAIConfig({
    required String primaryProvider,
    String? primaryApiKey,
    String? primaryModel,
    String? primaryBaseUrl,
    String? fallbackProvider,
    String? fallbackApiKey,
    String? fallbackModel,
    String? fallbackBaseUrl,
  }) async {
    try {
      final response = await dio.post(
        '/api/settings/ai-config',
        data: {
          'primary_provider': primaryProvider,
          if (primaryApiKey != null) 'primary_api_key': primaryApiKey,
          if (primaryModel != null) 'primary_model': primaryModel,
          if (primaryBaseUrl != null) 'primary_base_url': primaryBaseUrl,
          if (fallbackProvider != null) 'fallback_provider': fallbackProvider,
          if (fallbackApiKey != null) 'fallback_api_key': fallbackApiKey,
          if (fallbackModel != null) 'fallback_model': fallbackModel,
          if (fallbackBaseUrl != null) 'fallback_base_url': fallbackBaseUrl,
        },
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<List<AIModelOption>> fetchModels({
    required String provider,
    String? apiKey,
    String? baseUrl,
  }) async {
    try {
      final response = await dio.post(
        '/api/settings/fetch-models',
        data: {
          'provider': provider,
          if (apiKey != null) 'api_key': apiKey,
          if (baseUrl != null) 'base_url': baseUrl,
        },
      );
      final rawList =
          (response.data as Map<String, dynamic>)['models'] as List? ?? [];
      return rawList
          .map((item) => AIModelOption.fromJson(item as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  Future<Map<String, dynamic>> testAIConnection({
    required String provider,
    String? apiKey,
    String? model,
    String? baseUrl,
  }) async {
    try {
      final response = await dio.post(
        '/api/settings/test-connection',
        data: {
          'provider': provider,
          if (apiKey != null) 'api_key': apiKey,
          if (model != null) 'model': model,
          if (baseUrl != null) 'base_url': baseUrl,
        },
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      throw _handleDioError(e);
    }
  }

  // --- Error Handling ---

  AppError _handleDioError(DioException e) {
    if (e.response?.data is Map<String, dynamic>) {
      return AppError.fromJson(e.response!.data as Map<String, dynamic>);
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError) {
      return const AppError(
        code: 'NETWORK_ERROR',
        message: "Can't reach Athena backend",
      );
    }
    return AppError(
      code: 'INTERNAL',
      message: e.message ?? 'Something went wrong. Please try again.',
    );
  }
}
