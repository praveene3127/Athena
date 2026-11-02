import 'dart:async';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:athena/core/config/config.dart';
import 'package:athena/core/api/lan_discovery.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/lossless_chunker.dart';

String _extractEpubText(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final buffer = StringBuffer();
    final htmlFiles = archive.files.where((f) {
      final n = f.name.toLowerCase();
      return f.isFile &&
          (n.endsWith('.xhtml') || n.endsWith('.html') || n.endsWith('.htm'));
    }).toList();

    for (final file in htmlFiles) {
      final raw = file.content;
      if (raw is List<int>) {
        final content = utf8.decode(raw, allowMalformed: true);
        final text = content
            .replaceAll(
                RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
                ' ')
            .replaceAll(
                RegExp(r'<script[^>]*>[\s\S]*?</script>',
                    caseSensitive: false),
                ' ')
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll('&nbsp;', ' ')
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'")
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.isNotEmpty) {
          buffer.writeln(text);
          buffer.writeln();
        }
      }
    }
    return buffer.toString().trim();
  } catch (_) {
    return '';
  }
}

class _ParseDocumentParams {
  final List<int> bytes;
  final String fileName;
  final String docId;

  const _ParseDocumentParams({
    required this.bytes,
    required this.fileName,
    required this.docId,
  });
}

class _ParseDocumentResult {
  final String canonicalText;
  final int pageCount;
  final List<Map<String, Object?>> chunkMaps;

  const _ParseDocumentResult({
    required this.canonicalText,
    required this.pageCount,
    required this.chunkMaps,
  });
}

_ParseDocumentResult _parseAndChunkDocumentInBackground(_ParseDocumentParams params) {
  final bytes = params.bytes;
  final fileName = params.fileName;
  final docId = params.docId;
  final lowerName = fileName.toLowerCase();
  String canonicalText = '';
  int pageCount = 1;

  if (lowerName.endsWith('.pdf')) {
    try {
      final PdfDocument pdfDoc = PdfDocument(inputBytes: bytes);
      pageCount = pdfDoc.pages.count;
      final PdfTextExtractor extractor = PdfTextExtractor(pdfDoc);
      canonicalText = extractor.extractText();
      pdfDoc.dispose();
    } catch (_) {
      try {
        canonicalText = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        canonicalText = String.fromCharCodes(bytes);
      }
    }
  } else if (lowerName.endsWith('.epub')) {
    canonicalText = _extractEpubText(bytes);
    if (canonicalText.isEmpty) {
      try {
        canonicalText = utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        canonicalText = String.fromCharCodes(bytes);
      }
    }
  } else {
    try {
      canonicalText = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      canonicalText = String.fromCharCodes(bytes);
    }
  }

  canonicalText = canonicalText.trim();
  if (canonicalText.isEmpty) {
    canonicalText = 'Document: $fileName\n\nPreserved text content.';
  }

  final chunkMaps = LosslessChunker().build(
    documentId: docId,
    canonicalText: canonicalText,
    spans: [
      {
        'start': 0,
        'end': canonicalText.length,
        'page_start': 1,
        'page_end': pageCount,
        'type': 'paragraph',
      },
    ],
  );

  return _ParseDocumentResult(
    canonicalText: canonicalText,
    pageCount: pageCount,
    chunkMaps: chunkMaps,
  );
}

class ApiClient {
  final Dio dio;

  ApiClient({Dio? client})
      : dio = client ??
            Dio(
              BaseOptions(
                baseUrl: AppConfig.apiBaseUrl,
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: const Duration(seconds: 15),
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
    // 1. In standalone mobile mode, read directly from SQLite
    if (AppConfig.apiBaseUrl.isEmpty && !kIsWeb) {
      final localDocs = await LocalDatabase.instance.listDocuments();
      return localDocs;
    }

    try {
      final response = await dio
          .get('/api/documents')
          .timeout(const Duration(seconds: 3));
      final list = (response.data as List).cast<Map<String, dynamic>>();
      _cacheDocumentsLocally(list);
      return list;
    } catch (_) {
      if (!kIsWeb) {
        final localDocs = await LocalDatabase.instance.listDocuments();
        if (localDocs.isNotEmpty) {
          return localDocs;
        }
      }
      final cached = await _loadCachedDocuments();
      if (cached.isNotEmpty) {
        return cached;
      }
      if (!kIsWeb) {
        if (AppConfig.isCustomServerConfigured) {
          try {
            final found = await LanDiscovery.discoverServer(timeoutMs: 600);
            if (found != null && found.isNotEmpty) {
              await AppConfig.setBaseUrl(found);
              final retryResp = await dio
                  .get('/api/documents')
                  .timeout(const Duration(seconds: 3));
              final list = (retryResp.data as List).cast<Map<String, dynamic>>();
              _cacheDocumentsLocally(list);
              return list;
            }
          } catch (_) {}
        }
        // In standalone mode, return empty library without nagging
        return [];
      }
      throw AppError(
        code: 'NETWORK_ERROR',
        message:
            'Cannot connect to Athena backend at ${AppConfig.apiBaseUrl}. Please ensure your phone and laptop are on the same Wi-Fi.',
      );
    }
  }

  Future<Map<String, dynamic>> getDocument(String id) async {
    try {
      final response = await dio
          .get('/api/documents/$id')
          .timeout(const Duration(seconds: 3));
      return response.data as Map<String, dynamic>;
    } catch (_) {
      if (!kIsWeb) {
        final doc = await LocalDatabase.instance.getDocument(id);
        if (doc != null) return doc;
      }
      throw const AppError(code: 'NOT_FOUND', message: 'Document not found');
    }
  }

  Future<Map<String, dynamic>> getDocumentStatus(String id) async {
    try {
      final response = await dio
          .get('/api/documents/$id/status')
          .timeout(const Duration(seconds: 2));
      return response.data as Map<String, dynamic>;
    } catch (_) {
      if (!kIsWeb) {
        final doc = await LocalDatabase.instance.getDocument(id);
        if (doc != null) {
          return {
            'document_id': id,
            'status': doc['status'] ?? 'ready',
            'stage': doc['stage'] ?? 'done',
            'stage_label': doc['stage_label'] ?? 'Ready to read',
            'percent': doc['percent'] ?? 100,
          };
        }
      }
      throw const AppError(code: 'NOT_FOUND', message: 'Document not found');
    }
  }

  Future<String> uploadDocument(
    Stream<List<int>>? fileStream,
    int fileSize,
    String fileName, {
    void Function(int, int)? onSendProgress,
    CancelToken? cancelToken,
    String? filePath,
    List<int>? fileBytes,
  }) async {
    // 1. If companion engine backend is reachable, try backend first
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        FormData formData;
        if (!kIsWeb && filePath != null && filePath.isNotEmpty) {
          formData = FormData.fromMap({
            'file': await MultipartFile.fromFile(
              filePath,
              filename: fileName,
            ),
          });
        } else if (fileBytes != null && fileBytes.isNotEmpty) {
          formData = FormData.fromMap({
            'file': MultipartFile.fromBytes(
              fileBytes,
              filename: fileName,
            ),
          });
        } else if (fileStream != null) {
          formData = FormData.fromMap({
            'file': MultipartFile.fromStream(
              () => fileStream,
              fileSize,
              filename: fileName,
            ),
          });
        } else {
          throw const AppError(
            code: 'PDF_UNREADABLE',
            message: 'Could not access the selected book file.',
          );
        }

        final response = await dio.post(
          '/api/documents/upload',
          data: formData,
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 10),
          ),
          onSendProgress: onSendProgress,
          cancelToken: cancelToken,
        );
        final resData = response.data as Map<String, dynamic>;
        return (resData['document_id'] ?? resData['id']) as String;
      } catch (e) {
        if (kIsWeb) {
          if (e is DioException) throw _handleDioError(e);
          rethrow;
        }
        if (e is DioException &&
            e.response != null &&
            e.response!.statusCode != null &&
            e.response!.statusCode! < 500 &&
            e.response!.statusCode != 404) {
          // Explicit bouncer rejection
          throw _handleDioError(e);
        }
        // Backend offline or unreachable on mobile — seamlessly fall through to on-device ingestion
      }
    }

    // 2. On-device standalone extraction and lossless chunking
    final docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    final bytes = <int>[];
    if (fileBytes != null && fileBytes.isNotEmpty) {
      bytes.addAll(fileBytes);
    } else if (fileStream != null) {
      await for (final chunk in fileStream) {
        bytes.addAll(chunk);
      }
    } else if (filePath != null && filePath.isNotEmpty) {
      try {
        final xf = XFile(filePath);
        bytes.addAll(await xf.readAsBytes());
      } catch (_) {}
    }

    if (bytes.isEmpty) {
      throw const AppError(
        code: 'PDF_UNREADABLE',
        message: 'Could not read bytes from the selected file.',
      );
    }

    final parseResult = await compute(
      _parseAndChunkDocumentInBackground,
      _ParseDocumentParams(
        bytes: bytes,
        fileName: fileName,
        docId: docId,
      ),
    );

    final canonicalText = parseResult.canonicalText;
    final pageCount = parseResult.pageCount;
    final chunkMaps = parseResult.chunkMaps;

    final now = DateTime.now().toIso8601String();
    final cleanTitle = fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');

    await LocalDatabase.instance.insertDocument({
      'id': docId,
      'filename': fileName,
      'title': cleanTitle,
      'status': 'ready',
      'stage': 'done',
      'stage_label': 'Ready to read',
      'percent': 100,
      'page_count': pageCount,
      'processed_page': pageCount,
      'file_path': filePath ?? 'local://$fileName',
      'canonical_text': canonicalText,
      'integrity_verified': 1,
      'context_status': 'ready',
      'created_at': now,
      'updated_at': now,
    });

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
    if (!kIsWeb) {
      try {
        await LocalDatabase.instance.deleteDocument(id);
      } catch (_) {}
    }
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        await dio.delete('/api/documents/$id');
      } catch (_) {}
    }
  }

  // --- Reader ---

  Future<Map<String, dynamic>> getReader(String id) async {
    try {
      final response = await dio
          .get('/api/documents/$id/reader')
          .timeout(const Duration(seconds: 3));
      final data = response.data as Map<String, dynamic>;
      _cacheReaderLocally(id, data);
      return data;
    } catch (_) {
      if (!kIsWeb) {
        final dbData = await LocalDatabase.instance.getReaderData(id);
        final chunks = dbData['chunks'] as List?;
        if (chunks != null && chunks.isNotEmpty) {
          return dbData;
        }
      }
      final cached = await _loadCachedReader(id);
      if (cached != null && cached.isNotEmpty) return cached;
      throw const AppError(code: 'NOT_FOUND', message: 'Reader data not found');
    }
  }

  Future<Map<String, dynamic>?> generateCardForChunk(
    String docId,
    int chunkIndex, {
    bool forceNew = false,
  }) async {
    try {
      final response = await dio.post(
        '/api/documents/$docId/cards/generate',
        data: {'chunk_index': chunkIndex, 'force_new': forceNew},
        options: Options(receiveTimeout: const Duration(seconds: 12)),
      );
      return response.data as Map<String, dynamic>;
    } catch (_) {
      return null;
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
    if (cached != null) {
      final qLower = trimmed.toLowerCase();
      final chunks = (cached['chunks'] as List?) ??
          ((cached['items'] as List?)
              ?.where((it) => it is Map && it['type'] == 'reading_chunk')
              .toList()) ??
          [];
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
      final existingLocal = await _loadCachedDocuments();
      final merged = <Map<String, dynamic>>[...list];
      for (final local in existingLocal) {
        final id = local['id']?.toString();
        if (id != null &&
            (id.startsWith('doc_') || !merged.any((m) => m['id'] == id))) {
          merged.add(local);
        }
      }
      await prefs.setString('cached_documents_list', jsonEncode(merged));
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
        final rawChunks = (data['chunks'] as List?) ??
            ((data['items'] as List?)
                ?.where((it) => it is Map && it['type'] == 'reading_chunk')
                .toList());
        final rawCards = (data['cards'] as List?) ??
            ((data['items'] as List?)
                ?.where((it) => it is Map && it['type'] == 'context_card')
                .toList());
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
        if (rawCards != null && rawCards.isNotEmpty) {
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
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('reader_cache_$docId');
      if (raw != null && raw.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(raw) as Map);
      }
      if (!kIsWeb) {
        final dbData = await LocalDatabase.instance.getReaderData(docId);
        final chunks = dbData['chunks'] as List?;
        if (chunks != null && chunks.isNotEmpty) {
          return dbData;
        }
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

  Future<String?> localPdfPath(String documentId) async {
    if (!kIsWeb) {
      try {
        final doc = await LocalDatabase.instance.getDocument(documentId);
        final path = doc?['file_path']?.toString();
        if (path != null && path.isNotEmpty && !path.startsWith('local://')) {
          final xf = XFile(path);
          final len = await xf.length();
          if (len > 0) return path;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<Map<String, dynamic>> fetchVibeCheck(
      String docId, int chunkIndex) async {
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.post(
          '/api/documents/$docId/vibe-check',
          data: {'chunk_index': chunkIndex},
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        return response.data as Map<String, dynamic>;
      } catch (_) {}
    }

    return {
      'vibe': 'Key Insight',
      'summary': "A foundational turning point in the author's thesis.",
    };
  }

  // --- Cards & Saved (Phase 5) ---

  Future<void> saveUserQuote({
    required String id,
    required String documentId,
    required String chunkId,
    required String title,
    required String quoteText,
    String? exactQuote,
    String? documentTitle,
  }) async {
    final noteMap = {
      'id': id,
      'document_id': documentId,
      'source_chunk_id': chunkId,
      'concept_name': 'Saved Passage',
      'card_type': 'user_highlight',
      'title': title,
      'body': quoteText,
      'why_here': (documentTitle != null && documentTitle.isNotEmpty) ? 'From: $documentTitle' : 'Saved directly by reader',
      'exact_quote': exactQuote ??
          (quoteText.length > 280
              ? '${quoteText.substring(0, 280)}…'
              : quoteText),
      'citations_json': '[]',
      'saved': 1,
      'dismissed': 0,
      'created_at': DateTime.now().toIso8601String(),
    };

    if (!kIsWeb) {
      try {
        await LocalDatabase.instance.insertCards([noteMap]);
      } catch (_) {}
    }

    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        await dio.post('/api/cards/quote', data: {
          'id': id,
          'document_id': documentId,
          'source_chunk_id': chunkId,
          'title': title,
          'body': quoteText,
          'exact_quote': exactQuote ?? quoteText,
          if (documentTitle != null) 'document_title': documentTitle,
        });
      } catch (_) {}
    }
  }

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
    final List<Map<String, dynamic>> result = [];
    if (!kIsWeb) {
      try {
        final local = await LocalDatabase.instance.getSavedCards();
        result.addAll(local);
      } catch (_) {}
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedNotesRaw = prefs.getString('athena_saved_notes_v1');
      if (savedNotesRaw != null && savedNotesRaw.isNotEmpty) {
        final List decoded = jsonDecode(savedNotesRaw) as List;
        for (final item in decoded) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            if (!result.any((r) => r['id'] == map['id'])) {
              result.add(map);
            }
          }
        }
      }
    } catch (_) {}

    if (AppConfig.hasActiveBackend) {
      try {
        final response = await dio.get('/api/saved');
        final backendCards =
            (response.data as List).cast<Map<String, dynamic>>();
        for (final card in backendCards) {
          if (!result.any((r) => r['id'] == card['id'])) {
            result.add(card);
          }
        }
      } catch (_) {
        // Backend offline — return locally gathered saved cards
      }
    }

    return result;
  }

  // --- Ask (Phase 6) ---

  Future<Map<String, dynamic>> askAboutPassage({
    required String documentId,
    required String chunkId,
    required String question,
    String? selectedText,
    String? passageText,
  }) async {
    // 1. Try companion engine backend if configured
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.post(
          '/api/ask',
          data: {
            'document_id': documentId,
            'chunk_id': chunkId,
            'question': question,
            'passage_text': passageText ?? selectedText ?? '',
            if (selectedText != null) 'selected_text': selectedText,
          },
          options: Options(
            sendTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
        final data = response.data as Map<String, dynamic>;
        final answer = data['answer']?.toString();
        if (data['status'] == 'ok' || (answer != null && answer.trim().isNotEmpty)) {
          return {
            'status': 'ok',
            'answer': answer,
            'citations': data['citations'] ?? [],
            'source': 'backend',
          };
        }
      } catch (_) {}
    }

    // 2. Fetch passage text from LocalDatabase if needed
    var textForPrompt = passageText ?? selectedText ?? '';
    if (textForPrompt.isEmpty && !kIsWeb) {
      try {
        final chunk = await LocalDatabase.instance.getChunk(chunkId);
        if (chunk != null) {
          textForPrompt = chunk['raw_text']?.toString() ?? '';
        }
      } catch (_) {}
    }

    // 3. On-device fallback via configured Gemini or AI key directly over HTTPS
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = prefs.getString('athena_ai_primary_api_key') ?? '';
      final provider =
          prefs.getString('athena_ai_primary_provider') ?? 'gemini';
      final model =
          prefs.getString('athena_ai_primary_model') ?? 'gemini-2.5-flash';

      if (key.isNotEmpty) {
        final prompt =
            'You are Athena, a thoughtful literary reading companion.\n'
            '${selectedText != null ? "Selected Context: $selectedText\n\n" : (textForPrompt.isNotEmpty ? "Passage: $textForPrompt\n\n" : "")}'
            'User Question: $question\n\n'
            'Please provide a clear, concise (under 120 words), insightful explanation directly answering the question.';

        if (provider == 'gemini') {
          final effectiveModel = model.isNotEmpty ? model : 'gemini-2.5-flash';
          final url =
              'https://generativelanguage.googleapis.com/v1beta/models/$effectiveModel:generateContent?key=$key';
          final resp = await Dio().post(
            url,
            data: {
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ]
            },
            options: Options(receiveTimeout: const Duration(seconds: 15)),
          );
          if (resp.statusCode == 200 && resp.data is Map) {
            final cand = (resp.data['candidates'] as List?)?.firstOrNull;
            final part =
                (cand?['content']?['parts'] as List?)?.firstOrNull;
            final text = part?['text']?.toString() ?? '';
            if (text.isNotEmpty) {
              return {
                'status': 'ok',
                'answer': text.trim(),
                'citations': [],
                'source': 'direct_gemini',
              };
            }
          }
        } else if (provider == 'groq' ||
            provider == 'openrouter' ||
            provider == 'openai' ||
            provider == 'custom') {
          String compUrl;
          if (provider == 'groq') {
            compUrl = 'https://api.groq.com/openai/v1/chat/completions';
          } else if (provider == 'openai') {
            compUrl = 'https://api.openai.com/v1/chat/completions';
          } else if (provider == 'openrouter') {
            compUrl = 'https://openrouter.ai/api/v1/chat/completions';
          } else {
            final b = (prefs.getString('athena_ai_primary_base_url') ??
                    'https://api.openai.com/v1')
                .replaceAll(RegExp(r'/+$'), '');
            compUrl = b.endsWith('/chat/completions')
                ? b
                : '$b/chat/completions';
          }

          final resp = await Dio().post(
            compUrl,
            data: {
              'model': model.isNotEmpty
                  ? model
                  : (provider == 'groq'
                      ? 'llama-3.3-70b-versatile'
                      : 'gpt-4o-mini'),
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'You are Athena, a thoughtful literary reading companion.'
                },
                {'role': 'user', 'content': prompt},
              ],
              'max_tokens': 200,
            },
            options: Options(
              headers: {
                'Authorization': 'Bearer $key',
                'Content-Type': 'application/json',
              },
              receiveTimeout: const Duration(seconds: 15),
            ),
          );
          if (resp.statusCode == 200 && resp.data is Map) {
            final choice = (resp.data['choices'] as List?)?.firstOrNull;
            final text = choice?['message']?['content']?.toString() ?? '';
            if (text.isNotEmpty) {
              return {
                'status': 'ok',
                'answer': text.trim(),
                'citations': [],
                'source': 'direct_$provider',
              };
            }
          }
        }
      }
    } catch (_) {}

    // 4. Grounded passage fallback
    final rawText = (selectedText != null && selectedText.isNotEmpty)
        ? selectedText
        : textForPrompt;
    if (rawText.isNotEmpty) {
      final sentences = rawText
          .split(RegExp(r'(?<=[.!?])\s+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (sentences.isNotEmpty) {
        String relevantSentence = sentences.first;
        for (final s in sentences) {
          if (question
              .toLowerCase()
              .split(' ')
              .any((w) => w.length > 3 && s.toLowerCase().contains(w))) {
            relevantSentence = s;
            break;
          }
        }
        return {
          'status': 'ok',
          'answer': 'From this passage: "$relevantSentence"',
          'citations': [],
          'source': 'offline_grounded',
        };
      }
    }

    return {
      'status': 'ok',
      'answer':
          "Athena analyzed this passage in the context of the book's central theme. Connect to the Athena server or add a Gemini API key in Settings to unlock deep analytical synthesis.",
      'citations': [],
      'source': 'offline_fallback',
    };
  }

  // --- BYOK Multi-Provider AI Settings ---

  Future<AIConfig> getAIConfig() async {
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio
            .get('/api/settings/ai-config')
            .timeout(const Duration(seconds: 2));
        final cfg = AIConfig.fromJson(response.data as Map<String, dynamic>);
        if (cfg.isConfigured) return cfg;
      } catch (_) {}
    }

    // Read from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final pKey = prefs.getString('athena_ai_primary_api_key');
    final pProv = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
    final pModel =
        prefs.getString('athena_ai_primary_model') ?? '';
    final pBase = prefs.getString('athena_ai_primary_base_url');
    final fKey = prefs.getString('athena_ai_fallback_api_key');
    final fProv = prefs.getString('athena_ai_fallback_provider');
    final fModel = prefs.getString('athena_ai_fallback_model');
    final fBase = prefs.getString('athena_ai_fallback_base_url');

    return AIConfig(
      isConfigured: pKey != null && pKey.isNotEmpty,
      primaryProvider: pProv,
      primaryModel: pModel,
      primaryApiKeyMasked: pKey != null && pKey.length > 8
          ? '${pKey.substring(0, 4)}...${pKey.substring(pKey.length - 4)}'
          : (pKey != null ? '****' : null),
      primaryBaseUrl: pBase,
      fallbackProvider: fProv,
      fallbackModel: fModel,
      fallbackApiKeyMasked: fKey != null && fKey.length > 8
          ? '${fKey.substring(0, 4)}...${fKey.substring(fKey.length - 4)}'
          : (fKey != null ? '****' : null),
      fallbackBaseUrl: fBase,
    );
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
    // 1. ALWAYS persist to SharedPreferences FIRST
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('athena_ai_primary_provider', primaryProvider);
    if (primaryApiKey != null && !primaryApiKey.contains('...')) {
      await prefs.setString('athena_ai_primary_api_key', primaryApiKey);
    }
    if (primaryModel != null && primaryModel.isNotEmpty) {
      await prefs.setString('athena_ai_primary_model', primaryModel);
    }
    if (primaryBaseUrl != null) {
      await prefs.setString('athena_ai_primary_base_url', primaryBaseUrl);
    }
    if (fallbackProvider != null) {
      await prefs.setString('athena_ai_fallback_provider', fallbackProvider);
    }
    if (fallbackApiKey != null && !fallbackApiKey.contains('...')) {
      await prefs.setString('athena_ai_fallback_api_key', fallbackApiKey);
    }
    if (fallbackModel != null && fallbackModel.isNotEmpty) {
      await prefs.setString('athena_ai_fallback_model', fallbackModel);
    }
    if (fallbackBaseUrl != null) {
      await prefs.setString('athena_ai_fallback_base_url', fallbackBaseUrl);
    }

    // 2. Try companion backend, if unreachable, do not throw
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.post(
          '/api/settings/ai-config',
          data: {
            'primary_provider': primaryProvider,
            if (primaryApiKey != null) 'primary_api_key': primaryApiKey,
            if (primaryModel != null) 'primary_model': primaryModel,
            if (primaryBaseUrl != null) 'primary_base_url': primaryBaseUrl,
            if (fallbackProvider != null)
              'fallback_provider': fallbackProvider,
            if (fallbackApiKey != null) 'fallback_api_key': fallbackApiKey,
            if (fallbackModel != null) 'fallback_model': fallbackModel,
            if (fallbackBaseUrl != null)
              'fallback_base_url': fallbackBaseUrl,
          },
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        return response.data as Map<String, dynamic>;
      } catch (_) {
        // Backend offline on mobile — perfectly fine, saved locally
      }
    }

    return {'status': 'success', 'message': 'Saved on device'};
  }

  Future<List<AIModelOption>> fetchModels({
    required String provider,
    String? apiKey,
    String? baseUrl,
  }) async {
    final pKey = provider.toLowerCase();

    // 1. Try companion backend
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.post(
          '/api/settings/fetch-models',
          data: {
            'provider': provider,
            if (apiKey != null) 'api_key': apiKey,
            if (baseUrl != null) 'base_url': baseUrl,
          },
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        final rawList =
            (response.data as Map<String, dynamic>)['models'] as List? ?? [];
        if (rawList.isNotEmpty) {
          return rawList
              .map((item) =>
                  AIModelOption.fromJson(item as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }

    // 2. Direct on-device models discovery for Gemini
    if (pKey == 'gemini') {
      final cleanKey = (apiKey ?? '').trim();
      final List<AIModelOption> defaultGemini = const [
        AIModelOption(id: 'gemini-2.5-flash', name: 'Gemini 2.5 Flash'),
        AIModelOption(id: 'gemini-2.5-pro', name: 'Gemini 2.5 Pro'),
        AIModelOption(id: 'gemini-2.0-flash', name: 'Gemini 2.0 Flash'),
      ];
      if (cleanKey.isEmpty) return defaultGemini;

      try {
        final client = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 6),
        ));
        final mResp = await client.get(
            'https://generativelanguage.googleapis.com/v1beta/models?key=$cleanKey');
        if (mResp.statusCode == 200 && mResp.data is Map) {
          final rawModels = (mResp.data as Map)['models'] as List? ?? [];
          final List<AIModelOption> models = [];
          for (final item in rawModels) {
            if (item is! Map) continue;
            final mName = item['name']?.toString() ?? '';
            final slug =
                mName.startsWith('models/') ? mName.substring(7) : mName;
            final methods =
                (item['supportedGenerationMethods'] as List?)?.cast<String>() ??
                    [];
            if (methods.isNotEmpty && !methods.contains('generateContent')) {
              continue;
            }
            final low = slug.toLowerCase();
            if (low.contains('embedding') ||
                low.contains('tts') ||
                low.contains('whisper') ||
                low.contains('aqa') ||
                low.contains('imagen')) {
              continue;
            }
            models.add(AIModelOption(
              id: slug,
              name: item['displayName'] ?? slug,
            ));
          }
          if (models.isNotEmpty) return models;
        }
      } catch (_) {}
      return defaultGemini;
    }

    // 3. Direct on-device models discovery for other providers
    final res = await directTestProvider(
      provider: provider,
      apiKey: apiKey,
      baseUrl: baseUrl,
    );
    final rawList = res['models'] as List? ?? [];
    if (rawList.isNotEmpty) {
      return rawList.map((m) {
        if (m is Map) {
          return AIModelOption(
            id: m['id']?.toString() ?? '',
            name: m['name']?.toString() ?? m['id']?.toString() ?? '',
          );
        }
        return AIModelOption(id: m.toString(), name: m.toString());
      }).toList();
    }

    if (pKey == 'groq') {
      return const [
        AIModelOption(
            id: 'llama-3.3-70b-versatile', name: 'Llama 3.3 70B Versatile'),
        AIModelOption(id: 'llama-3.1-8b-instant', name: 'Llama 3.1 8B Instant'),
      ];
    } else if (pKey == 'openai') {
      return const [
        AIModelOption(id: 'gpt-4o-mini', name: 'GPT-4o Mini'),
        AIModelOption(id: 'gpt-4o', name: 'GPT-4o'),
      ];
    } else if (pKey == 'anthropic') {
      return const [
        AIModelOption(
            id: 'claude-3-5-haiku-20241022', name: 'Claude 3.5 Haiku'),
        AIModelOption(
            id: 'claude-3-5-sonnet-20241022', name: 'Claude 3.5 Sonnet'),
      ];
    }

    return const [];
  }

  static Future<Map<String, dynamic>> directTestProvider({
    required String provider,
    String? apiKey,
    String? model,
    String? baseUrl,
  }) async {
    final cleanKey = (apiKey ?? '').trim();
    final pKey = provider.toLowerCase();

    if (cleanKey.isEmpty && pKey != 'custom') {
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': 0,
        'message': 'API key is required to test connection',
        'models': [],
      };
    }

    final sw = Stopwatch()..start();
    final client = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        sendTimeout: const Duration(seconds: 6),
      ),
    );

    try {
      if (pKey == 'gemini') {
        final targetModel = (model != null && model.isNotEmpty) ? model : 'gemini-2.5-flash';
        final genUrl =
            'https://generativelanguage.googleapis.com/v1beta/models/$targetModel:generateContent?key=$cleanKey';
        final genResp = await client.post(
          genUrl,
          data: {
            'contents': [
              {
                'parts': [
                  {'text': 'Say OK'}
                ]
              }
            ]
          },
          options: Options(headers: {'Content-Type': 'application/json'}),
        );
        sw.stop();
        if (genResp.statusCode == 200) {
          List<Map<String, dynamic>> models = [
            {'id': 'gemini-2.5-flash', 'name': 'Gemini 2.5 Flash'},
            {'id': 'gemini-2.5-pro', 'name': 'Gemini 2.5 Pro'},
            {'id': 'gemini-2.0-flash', 'name': 'Gemini 2.0 Flash'},
          ];
          try {
            final modelsUrl =
                'https://generativelanguage.googleapis.com/v1beta/models?key=$cleanKey';
            final mResp = await client.get(modelsUrl);
            if (mResp.statusCode == 200 && mResp.data is Map) {
              final rawModels =
                  (mResp.data as Map)['models'] as List? ?? [];
              final List<Map<String, dynamic>> fetched = [];
              for (final item in rawModels) {
                if (item is! Map) continue;
                final mName = item['name']?.toString() ?? '';
                final slug = mName.startsWith('models/')
                    ? mName.substring(7)
                    : mName;
                final methods =
                    (item['supportedGenerationMethods'] as List?)
                            ?.cast<String>() ??
                        [];
                if (methods.isNotEmpty &&
                    !methods.contains('generateContent')) {
                  continue;
                }
                final low = slug.toLowerCase();
                if (low.contains('embedding') ||
                    low.contains('tts') ||
                    low.contains('whisper') ||
                    low.contains('aqa') ||
                    low.contains('imagen')) {
                  continue;
                }
                fetched.add({
                  'id': slug,
                  'name': item['displayName'] ?? slug,
                });
              }
              if (fetched.isNotEmpty) models = fetched;
            }
          } catch (_) {}

          return {
            'ok': true,
            'valid': true,
            'status': 'success',
            'latency_ms': sw.elapsedMilliseconds,
            'message': 'Connected to Google Gemini!',
            'models': models,
          };
        }
      } else if (pKey == 'anthropic') {
        final resp = await client.post(
          'https://api.anthropic.com/v1/messages',
          data: {
            'model': (model != null && model.isNotEmpty)
                ? model
                : 'claude-3-5-haiku-20241022',
            'max_tokens': 5,
            'messages': [
              {'role': 'user', 'content': 'Say OK'}
            ]
          },
          options: Options(
            headers: {
              'x-api-key': cleanKey,
              'anthropic-version': '2023-06-01',
              'Content-Type': 'application/json',
            },
          ),
        );
        sw.stop();
        if (resp.statusCode == 200) {
          return {
            'ok': true,
            'valid': true,
            'status': 'success',
            'latency_ms': sw.elapsedMilliseconds,
            'message': 'Connected to Anthropic Claude!',
            'models': [
              {'id': 'claude-3-5-haiku-20241022', 'name': 'Claude 3.5 Haiku'},
              {'id': 'claude-3-5-sonnet-20241022', 'name': 'Claude 3.5 Sonnet'},
            ],
          };
        }
      } else {
        // OpenAI-compatible: OpenRouter, Groq, OpenAI, DeepSeek, Custom
        String rootUrl;
        String completionUrl;
        if (pKey == 'groq') {
          rootUrl = 'https://api.groq.com/openai/v1/models';
          completionUrl = 'https://api.groq.com/openai/v1/chat/completions';
        } else if (pKey == 'openai') {
          rootUrl = 'https://api.openai.com/v1/models';
          completionUrl = 'https://api.openai.com/v1/chat/completions';
        } else if (pKey == 'openrouter') {
          rootUrl = 'https://openrouter.ai/api/v1/models';
          completionUrl = 'https://openrouter.ai/api/v1/chat/completions';
        } else if (pKey == 'deepseek') {
          rootUrl = 'https://api.deepseek.com/models';
          completionUrl = 'https://api.deepseek.com/chat/completions';
        } else {
          final b = (baseUrl ?? 'https://api.openai.com/v1')
              .replaceAll(RegExp(r'/+$'), '');
          rootUrl = b.endsWith('/models') ? b : '$b/models';
          completionUrl = b.endsWith('/chat/completions')
              ? b
              : '$b/chat/completions';
        }

        final headers = <String, dynamic>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          if (cleanKey.isNotEmpty) 'Authorization': 'Bearer $cleanKey',
        };

        // Try small completion test
        final testResp = await client.post(
          completionUrl,
          data: {
            'model': (model != null && model.isNotEmpty)
                ? model
                : (pKey == 'groq'
                    ? 'llama-3.3-70b-versatile'
                    : (pKey == 'deepseek'
                        ? 'deepseek-chat'
                        : 'gpt-4o-mini')),
            'messages': [
              {'role': 'user', 'content': 'OK'}
            ],
            'max_tokens': 5,
          },
          options: Options(headers: headers),
        );

        sw.stop();
        if (testResp.statusCode == 200) {
          // Discover models
          List<Map<String, dynamic>> models = [];
          try {
            final mResp = await client.get(rootUrl,
                options: Options(headers: headers));
            if (mResp.statusCode == 200) {
              List rawList = [];
              if (mResp.data is Map) {
                rawList = (mResp.data['data'] as List?) ??
                    (mResp.data['models'] as List?) ??
                    [];
              } else if (mResp.data is List) {
                rawList = mResp.data as List;
              }
              for (final item in rawList) {
                if (item is! Map) continue;
                final mid = item['id']?.toString() ??
                    item['name']?.toString() ??
                    '';
                if (mid.isNotEmpty) {
                  final low = mid.toLowerCase();
                  if (low.contains('embed') ||
                      low.contains('whisper') ||
                      low.contains('tts') ||
                      low.contains('dall-e')) {
                    continue;
                  }
                  models.add({'id': mid, 'name': item['name'] ?? mid});
                }
              }
            }
          } catch (_) {}

          return {
            'ok': true,
            'valid': true,
            'status': 'success',
            'latency_ms': sw.elapsedMilliseconds,
            'message': 'Connection verified successfully!',
            'models': models,
          };
        }
      }
    } on DioException catch (dioErr) {
      sw.stop();
      String detail = '';
      if (dioErr.response?.data is Map) {
        final d = dioErr.response!.data as Map;
        detail = d['error']?['message']?.toString() ??
            d['message']?.toString() ??
            dioErr.response?.statusMessage ??
            '';
      }
      if (detail.isEmpty) {
        detail = dioErr.message ?? 'Authentication or network failed';
      }
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': sw.elapsedMilliseconds,
        'message': detail,
        'models': [],
      };
    } catch (err) {
      sw.stop();
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': sw.elapsedMilliseconds,
        'message': err.toString(),
        'models': [],
      };
    }

    return {
      'ok': false,
      'valid': false,
      'status': 'error',
      'latency_ms': sw.elapsedMilliseconds,
      'message': 'Could not verify provider credentials.',
      'models': [],
    };
  }

  Future<Map<String, dynamic>> testAIConnection({
    required String provider,
    String? apiKey,
    String? model,
    String? baseUrl,
  }) async {
    final cleanKey = (apiKey ?? '').trim();

    // 1. Try companion engine backend first if configured and reachable
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final response = await dio.post(
          '/api/settings/test-connection',
          data: {
            'provider': provider,
            if (cleanKey.isNotEmpty) 'api_key': cleanKey,
            if (model != null) 'model': model,
            if (baseUrl != null) 'base_url': baseUrl,
          },
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        if (response.data is Map<String, dynamic>) {
          final res = response.data as Map<String, dynamic>;
          if (res['ok'] == true || res['valid'] == true) {
            return {
              'ok': true,
              'valid': true,
              'status': 'success',
              'message': res['message'] ?? 'Connected successfully.',
              'models': res['models'] ?? [],
            };
          }
        }
      } catch (_) {
        // Backend offline or unreachable — seamlessly test directly over HTTPS
      }
    }

    // 2. Direct on-device HTTPS verification
    return await directTestProvider(
      provider: provider,
      apiKey: cleanKey,
      model: model,
      baseUrl: baseUrl,
    );
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
