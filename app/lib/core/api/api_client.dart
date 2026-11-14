import 'dart:typed_data';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import 'package:athena/core/config/config.dart';
import 'package:athena/core/api/lan_discovery.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/models/ai_provider.dart';
import 'package:athena/services/ingestion_job_coordinator.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/services/secure_storage_service.dart';

String humanizeTitle(String raw) {
  var title = raw.trim();
  title = title.replaceAll(RegExp(r'\.(pdf|epub)$', caseSensitive: false), '');
  title = title.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
  title = title.replaceAll(
      RegExp(r'[\s_\-]+(?:\(?\d+\)?|EnglishPDF)\s*$', caseSensitive: false),
      '');
  title = title.replaceAll(RegExp(r'\s*\(\d+\)\s*$'), '');
  title = title.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'[\-]+'), ' ');
  title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (title.isEmpty) return 'Untitled Document';
  return title;
}

String extractEpubText(List<int> bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, ArchiveFile>{
      for (final file in archive.files)
        if (file.isFile) _normalizeEpubPath(file.name): file,
    };

    if (files.containsKey('META-INF/encryption.xml') || files.containsKey('META-INF/rights.xml')) {
      final encBytes = files['META-INF/encryption.xml']?.content;
      if (encBytes is List<int>) {
        final encXml = utf8.decode(encBytes, allowMalformed: true);
        if (encXml.contains('<EncryptedData') &&
            !encXml.contains('http://www.idpf.org/2008/embedding') &&
            !encXml.contains('http://ns.adobe.com/pdf/enc/font')) {
          throw const AppError(
            code: 'DRM_PROTECTED',
            message: 'This EPUB is DRM-protected and cannot be read.',
          );
        }
      }
    }

    final containerBytes = files['META-INF/container.xml']?.content;
    if (containerBytes is! List<int>) return '';
    final container = XmlDocument.parse(DocumentIngestionPipeline.decodeXmlBytes(containerBytes));
    final rootfile = container
        .findAllElements('rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    if (rootfile == null || rootfile.isEmpty) return '';

    final opfPath = _normalizeEpubPath(rootfile);
    final opfBytes = files[opfPath]?.content;
    if (opfBytes is! List<int>) return '';
    final package = XmlDocument.parse(DocumentIngestionPipeline.decodeXmlBytes(opfBytes));
    final manifest = <String, ({String href, String properties})>{};
    for (final item in package.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id == null || href == null) continue;
      manifest[id] = (
        href: href,
        properties: item.getAttribute('properties') ?? '',
      );
    }

    final spine = package.findAllElements('spine').firstOrNull;
    if (spine == null) return '';
    final parts = <String>[];
    for (final itemRef in spine.findElements('itemref')) {
      if ((itemRef.getAttribute('linear') ?? '').toLowerCase() == 'no') {
        continue;
      }
      final idref = itemRef.getAttribute('idref');
      final item = idref == null ? null : manifest[idref];
      final excludedByName = idref == null || item == null
          ? false
          : RegExp(r'^(toc|nav|ncx|cover|titlepage|copyright)',
                      caseSensitive: false)
                  .hasMatch(idref) ||
              RegExp(r'^(toc|nav|ncx|cover|titlepage|copyright)',
                      caseSensitive: false)
                  .hasMatch(item.href.split('/').last);
      if (item == null ||
          item.properties
              .split(RegExp(r'\s+'))
              .any((p) => p == 'nav' || p == 'cover-image') ||
          excludedByName) {
        continue;
      }
      if (!RegExp(r'\.(xhtml|html|htm)(?:$|[?#])', caseSensitive: false)
          .hasMatch(item.href)) {
        continue;
      }
      final path = _resolveEpubHref(opfPath, item.href);
      final contentBytes = files[path]?.content;
      if (contentBytes is! List<int>) continue;
      final content = utf8.decode(contentBytes, allowMalformed: true);
      final text = _epubMarkupToText(content);
      if (text.isNotEmpty) parts.add(sanitizeProseSpacing(text));
    }
    return parts.join('\n\n').trim();
  } on AppError {
    rethrow;
  } catch (e) {
    debugPrint('[Athena] EPUB spine parsing failed: $e');
    return '';
  }
}

String _normalizeEpubPath(String path) {
  final segments = <String>[];
  for (final segment in path.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else {
      segments.add(Uri.decodeComponent(segment));
    }
  }
  return segments.join('/');
}

String _resolveEpubHref(String opfPath, String href) {
  final decoded = Uri.decodeComponent(href.split('#').first.split('?').first);
  final opfDirectory = opfPath.contains('/')
      ? opfPath.substring(0, opfPath.lastIndexOf('/'))
      : '';
  return _normalizeEpubPath(
      opfDirectory.isEmpty ? decoded : '$opfDirectory/$decoded');
}

String _epubMarkupToText(String source) =>
    DocumentIngestionPipeline.decodeEpubHtmlToProse(source);

class ApiClient {
  static bool _backendReachable = true;
  static DateTime? _backendCircuitBreakerResetTime;

  static bool get isBackendReachable {
    if (!_backendReachable && _backendCircuitBreakerResetTime != null) {
      if (DateTime.now().isAfter(_backendCircuitBreakerResetTime!)) {
        _backendReachable = true;
        _backendCircuitBreakerResetTime = null;
      }
    }
    return _backendReachable;
  }

  static void recordBackendFailure({Object? error}) {
    if (error is DioException) {
      final type = error.type;
      final code = error.response?.statusCode;
      // Only trip circuit breaker on actual server unreachable / connection refused / 502/503/504
      final isConnectionIssue = type == DioExceptionType.connectionError ||
          type == DioExceptionType.connectionTimeout ||
          (code != null && code >= 502 && code <= 504);
      if (!isConnectionIssue) {
        return;
      }
    }
    _backendReachable = false;
    _backendCircuitBreakerResetTime =
        DateTime.now().add(const Duration(seconds: 15));
  }

  static void recordBackendSuccess() {
    _backendReachable = true;
    _backendCircuitBreakerResetTime = null;
  }

  bool get _hasReachableBackend =>
      AppConfig.apiBaseUrl.isNotEmpty &&
      !AppConfig.isStandaloneMobile &&
      isBackendReachable;

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
            } catch (e) {
              debugPrint('Athena caught error: $e');
            }
          }
          if (base.isNotEmpty) {
            options.baseUrl = base;
          }
          final fullUri = options.uri;
          if (fullUri.scheme == 'http' && !isPermittedHttpHost(fullUri.toString())) {
            return handler.reject(
              DioException(
                requestOptions: options,
                error: const AppError(
                  code: 'CLEARTEXT_NOT_PERMITTED',
                  message:
                      'Cleartext HTTP is strictly prohibited for non-local hosts. Use https:// or a private LAN IP.',
                ),
                type: DioExceptionType.cancel,
              ),
            );
          }
          final pairingToken = AppConfig.pairingToken;
          if (pairingToken.isNotEmpty) {
            options.headers['X-Athena-Pairing-Token'] = pairingToken;
          }
          return handler.next(options);
        },
      ),
    );
  }

  // --- Health ---

  Future<Map<String, dynamic>> checkHealth() async {
    if (!_hasReachableBackend || AppConfig.apiBaseUrl.isEmpty) {
      return {'status': 'ok', 'mode': 'on_device_standalone'};
    }
    try {
      final response = await dio.get('/api/health');
      recordBackendSuccess();
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      recordBackendFailure(error: e);
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
    } catch (e) {
      debugPrint('Athena generateCard caught: ');

      return null;
    }
  }

  // --- Documents ---

  Future<List<Map<String, dynamic>>> listDocuments() async {
    // 1. In standalone mobile mode or when circuit-breaker is tripped, read directly from SQLite (< 2ms)
    if ((!_hasReachableBackend || AppConfig.apiBaseUrl.isEmpty) && !kIsWeb) {
      final localDocs = await LocalDatabase.instance.listDocuments();
      return localDocs;
    }

    try {
      final response =
          await dio.get('/api/documents').timeout(const Duration(seconds: 3));
      final list = (response.data as List).cast<Map<String, dynamic>>();
      _cacheDocumentsLocally(list);
      return list;
    } catch (e) {
      recordBackendFailure();
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
              final list =
                  (retryResp.data as List).cast<Map<String, dynamic>>();
              _cacheDocumentsLocally(list);
              return list;
            }
          } catch (e) {
            debugPrint('Athena caught error: $e');
          }
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
    } catch (e) {
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
    } catch (e) {
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
    void Function(double progress, String stage)? onProgress,
  }) async {
    onProgress?.call(0.15, '1/4 Reading PDF bytes...');
    // 1. If companion engine backend is reachable, try backend first
    if (_hasReachableBackend) {
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
            sendTimeout: const Duration(minutes: 5),
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

    // 2. On-device standalone extraction and lossless chunking via unified DocumentIngestionPipeline
    final cleanTitle = humanizeTitle(fileName);

    // Resolve bytes from fileStream if neither filePath nor fileBytes was provided
    List<int>? bytes = fileBytes;
    if ((bytes == null || bytes.isEmpty) && (filePath == null || filePath.isEmpty) && fileStream != null) {
      try {
        final builder = BytesBuilder(copy: false);
        await for (final chunk in fileStream) {
          builder.add(chunk);
        }
        bytes = builder.takeBytes();
      } catch (e, st) {
        debugPrint('[Athena Error] Failed reading fileStream: $e\n$st');
      }
    }

    String docId;
    String? persistentPath = filePath;
    if (!kIsWeb) {
      try {
        if (filePath != null && filePath.isNotEmpty) {
          final sourceFile = File(filePath);
          if (sourceFile.existsSync()) {
            // Stream SHA-256 calculation without readAsBytesSync() into UI isolate RAM
            final digest = await sha256.bind(sourceFile.openRead()).first;
            final fileSha = digest.toString();
            docId = 'doc_${fileSha.substring(0, 16)}';

            final appDocDir = await getApplicationDocumentsDirectory();
            final ext = fileName.contains('.') ? '.${fileName.split('.').last}' : '.pdf';
            final booksDir = Directory('${appDocDir.path}/books');
            if (!booksDir.existsSync()) {
              booksDir.createSync(recursive: true);
            }
            final destFile = File('${booksDir.path}/$docId$ext');
            if (!destFile.existsSync() || destFile.lengthSync() != sourceFile.lengthSync()) {
              await sourceFile.copy(destFile.path);
            }
            persistentPath = destFile.path;

            try {
              await FilePicker.platform.clearTemporaryFiles();
            } catch (e) {
              debugPrint('[Athena Ingestion] FilePicker clear notice: $e');
            }

            // Pass file path only to worker, avoid keeping bytes in RAM
            bytes = null;
          } else {
            docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
          }
        } else if (bytes != null && bytes.isNotEmpty) {
          final fileSha = sha256.convert(bytes).toString();
          docId = 'doc_${fileSha.substring(0, 16)}';
          final appDocDir = await getApplicationDocumentsDirectory();
          final ext = fileName.contains('.') ? '.${fileName.split('.').last}' : '.pdf';
          final booksDir = Directory('${appDocDir.path}/books');
          if (!booksDir.existsSync()) {
            booksDir.createSync(recursive: true);
          }
          final destFile = File('${booksDir.path}/$docId$ext');
          if (!destFile.existsSync() || destFile.lengthSync() != bytes.length) {
            await destFile.writeAsBytes(bytes, flush: true);
          }
          persistentPath = destFile.path;
          bytes = null;
        } else {
          docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
        }
      } catch (e) {
        debugPrint('[Athena] File persist notice: $e');
        docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
      }
    } else {
      docId = 'doc_${DateTime.now().millisecondsSinceEpoch}';
    }

    // Never duplicate or wipe an existing document on re-import (F-B4, R1)
    if (!kIsWeb) {
      final existing = await LocalDatabase.instance.getDocument(docId);
      if (existing != null) {
        final existingStatus = existing['status'] as String?;
        if (existingStatus == 'ready') {
          onProgress?.call(1.0, 'Ready to read');
          return docId;
        } else {
          // Never reset existing non-ready books to page 1 unless redoFromScratch is explicitly confirmed
          unawaited(IngestionJobCoordinator.instance.startOrResume(docId));
          return docId;
        }
      }
    }

    final now = DateTime.now().toUtc().toIso8601String();
    onProgress?.call(0.05, '1/4 Initializing document library...');

    // Step A: Insert initial document record in DB
    try {
      await LocalDatabase.instance.insertDocument({
        'id': docId,
        'filename': fileName,
        'title': cleanTitle,
        'status': 'processing',
        'stage': 'extracting',
        'stage_label': 'Initializing document extraction...',
        'percent': 5,
        'page_count': 0,
        'processed_page': 0,
        'file_path': persistentPath ?? 'local://$fileName',
        'integrity_verified': 0,
        'context_status': 'pending',
        'created_at': now,
        'updated_at': now,
      });
    } catch (e) {
      debugPrint('[Athena Error] Initial insertDocument notice: $e');
    }

    // Fire and forget via single IngestionJobCoordinator orchestrator
    unawaited(IngestionJobCoordinator.instance.startOrResume(docId));
    return docId;
  }



  Future<void> continueDocument(String id) async {
    if (!kIsWeb) {
      if (AppConfig.apiBaseUrl.isNotEmpty) {
        try {
          await dio.post('/api/documents/$id/resume');
          return;
        } on DioException catch (e) {
          debugPrint(
              '[Athena ApiClient] continueDocument remote error: $e, falling back to local coordinator');
        }
      }
      await IngestionJobCoordinator.instance
          .startOrResume(id, redoFromScratch: false);
      return;
    }
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        await dio.post('/api/documents/$id/resume');
      } on DioException catch (e) {
        throw _handleDioError(e);
      }
    }
  }

  Future<void> retryDocument(String id, {bool redoFromScratch = false}) async {
    if (!kIsWeb) {
      if (AppConfig.apiBaseUrl.isNotEmpty) {
        try {
          await dio.post(
            redoFromScratch
                ? '/api/documents/$id/process'
                : '/api/documents/$id/resume',
          );
          return;
        } on DioException catch (e) {
          debugPrint(
              '[Athena ApiClient] retryDocument remote error: $e, falling back to local coordinator');
        }
      }
      await IngestionJobCoordinator.instance
          .startOrResume(id, redoFromScratch: redoFromScratch);
      return;
    }
    if (AppConfig.apiBaseUrl.isEmpty) return;
    try {
      await dio.post(
        redoFromScratch
            ? '/api/documents/$id/process'
            : '/api/documents/$id/resume',
      );
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
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        await dio.delete('/api/documents/$id');
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }
  }

  // --- Reader ---

  void _sanitizeReaderData(Map<String, dynamic> data) {
    // Reader payloads already contain canonical chunks. Never rewrite their
    // text or card quotes after hashing; cleanup belongs before ingestion only.
  }

  Future<Map<String, dynamic>> getReader(String id) async {
    // 1. Instant local read (< 2ms) when in standalone mobile mode or backend circuit-breaker tripped
    if ((!_hasReachableBackend || AppConfig.isStandaloneMobile) && !kIsWeb) {
      final dbData = await LocalDatabase.instance.getReaderData(id);
      final chunks = dbData['chunks'] as List?;
      if (chunks != null && chunks.isNotEmpty) {
        _sanitizeReaderData(dbData);
        return dbData;
      }
    }

    try {
      final response = await dio
          .get('/api/documents/$id/reader')
          .timeout(const Duration(seconds: 30));
      recordBackendSuccess();
      final data = Map<String, dynamic>.from(response.data as Map);

      // ISM-04: If companion server returns a windowed response (< total_chunks),
      // fetch remaining windows so books > 200 chunks are never truncated!
      final chunkCount = (data['integrity'] as Map?)?['chunk_count'] as int? ??
          ((data['document'] as Map?)?['integrity'] as Map?)?['chunk_count'] as int? ??
          (data['total_chunks'] as int? ?? (data['chunk_count'] as int? ?? 0));
      var chunksList = ((data['chunks'] as List?)?.cast<dynamic>() ?? []).toList();
      var itemsList = ((data['items'] as List?)?.cast<dynamic>() ?? []).toList();
      final currentLoadedChunks = chunksList.isNotEmpty
          ? chunksList.length
          : itemsList.where((it) => (it as Map)['type'] == 'reading_chunk').length;

      if (chunkCount > currentLoadedChunks) {
        int nextSeq = chunksList.isNotEmpty
            ? ((chunksList.last as Map)['sequence'] as int? ?? chunksList.length) + 1
            : (itemsList.isNotEmpty ? ((itemsList.last as Map)['sequence'] as int? ?? itemsList.length) + 1 : 1);
        while (chunksList.length < chunkCount && (itemsList.isEmpty || itemsList.where((it) => (it as Map)['type'] == 'reading_chunk').length < chunkCount)) {
          final nextResponse = await dio.get(
            '/api/documents/$id/reader',
            queryParameters: {'from_seq': nextSeq, 'limit': 500},
          ).timeout(const Duration(seconds: 30));
          final nextData = nextResponse.data as Map<String, dynamic>;
          final nextChunks = (nextData['chunks'] as List?)?.cast<dynamic>() ?? [];
          final nextItems = (nextData['items'] as List?)?.cast<dynamic>() ?? [];
          if (nextChunks.isEmpty && nextItems.isEmpty) break;
          if (nextChunks.isNotEmpty) chunksList.addAll(nextChunks);
          if (nextItems.isNotEmpty) itemsList.addAll(nextItems);
          final nextCards = (nextData['cards'] as List?)?.cast<dynamic>() ?? [];
          if (nextCards.isNotEmpty) {
            final cardsList = ((data['cards'] as List?)?.cast<dynamic>() ?? []).toList();
            cardsList.addAll(nextCards);
            data['cards'] = cardsList;
          }
          final lastChunk = nextChunks.isNotEmpty
              ? nextChunks.last as Map
              : (nextItems.isNotEmpty ? nextItems.last as Map : null);
          nextSeq = (lastChunk?['sequence'] as int? ?? (nextSeq + (nextChunks.isNotEmpty ? nextChunks.length : nextItems.length) - 1)) + 1;
          if (nextChunks.length < 500 && nextItems.length < 500) break;
        }
        data['chunks'] = chunksList;
        if (itemsList.isNotEmpty) data['items'] = itemsList;
      }

      _sanitizeReaderData(data);
      _cacheReaderLocally(id, data);
      return data;
    } catch (e) {
      recordBackendFailure(error: e);
      if (!kIsWeb) {
        final dbData = await LocalDatabase.instance.getReaderData(id);
        final chunks = dbData['chunks'] as List?;
        if (chunks != null && chunks.isNotEmpty) {
          _sanitizeReaderData(dbData);
          return dbData;
        }
      }
      final cached = await _loadCachedReader(id);
      if (cached != null && cached.isNotEmpty) {
        _sanitizeReaderData(cached);
        return cached;
      }
      throw const AppError(code: 'NOT_FOUND', message: 'Reader data not found');
    }
  }

  Future<Map<String, dynamic>?> generateCardForChunk(
    String docId,
    int chunkIndex, {
    String? chunkId,
    int? feedIndex,
    bool forceNew = false,
  }) async {
    try {
      final payload = <String, dynamic>{
        'chunk_index': chunkIndex,
        'force_new': forceNew,
      };
      if (chunkId != null) payload['chunk_id'] = chunkId;
      if (feedIndex != null) payload['feed_index'] = feedIndex;

      final response = await dio.post(
        '/api/documents/$docId/cards/generate',
        data: payload,
        options: Options(receiveTimeout: const Duration(seconds: 45)),
      );
      return response.data as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Athena generateCard caught: $e');
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
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // 1. Instant on-device SQLite FTS5 search (< 1ms)
    if (!kIsWeb) {
      final dbResults =
          await LocalDatabase.instance.searchChunks(docId, trimmed);
      if (dbResults.isNotEmpty) {
        return dbResults
            .map((r) => {
                  'chunk_id': r['id']?.toString() ?? '',
                  'sequence': (r['sequence'] as num?)?.toInt() ?? 1,
                  'section_title': r['section_title']?.toString() ?? '',
                  'raw_text': r['raw_text']?.toString() ?? '',
                  'rrf_score': 1.0,
                })
            .take(topK)
            .toList();
      }
    }

    // 2. Local substring search fallback over cached chunks if offline
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    return [];
  }

  Future<void> _cacheReaderLocally(
      String docId, Map<String, dynamic> data) async {
    try {
      if (kIsWeb) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('reader_cache_$docId', jsonEncode(data));
      } else {
        // Native mobile: SQLite (LocalDatabase.instance) is single source of truth.
        // Prevents giant JSON writes in SharedPreferences from freezing UI thread.
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
              'support_status':
                  map['support_status']?.toString() ?? 'unverified',
              'support_tier':
                  map['support_tier']?.toString() ?? 'internal_extractive',
              'canonical_sha256': map['canonical_sha256']?.toString() ?? '',
              'generation_mode':
                  map['generation_mode']?.toString() ?? 'grounded',
              'verified':
                  (map['verified'] == 1 || map['verified'] == true) ? 1 : 0,
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>> syncReadingProgress(
    String id,
    int chunkIndex, {
    String? chunkId,
    int? feedIndex,
    String readingMode = 'feed',
  }) async {
    if (AppConfig.hasActiveBackend && AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final payload = <String, dynamic>{
          'chunk_index': chunkIndex,
          'chunk_sequence': chunkIndex,
          'reading_mode': readingMode,
        };
        if (chunkId != null) payload['chunk_id'] = chunkId;
        if (feedIndex != null) payload['feed_index'] = feedIndex;

        final response = await dio.post(
          '/api/documents/$id/progress',
          data: payload,
        );
        if (response.data is Map<String, dynamic>) {
          return response.data as Map<String, dynamic>;
        }
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // Standalone on-device mobile mode (< 1ms single-row indexed update, zero getChunks calls)
    if (!kIsWeb) {
      try {
        await LocalDatabase.instance.updateReadingPosition(
          id,
          chunkIndex: chunkIndex,
          chunkId: chunkId,
          readingMode: readingMode,
        );
      } catch (e) {
        debugPrint('Athena syncReadingProgress error: $e');
      }
    }

    return {'status': 'saved', 'chunk_index': chunkIndex};
  }

  Future<Map<String, dynamic>?> generateImmediateCard(
    String documentId,
    String chunkId,
    int sequence,
    String rawText,
  ) async {
    try {
      final chunk = {
        'id': chunkId,
        'sequence': sequence,
        'raw_text': rawText,
        'canonical_sha256': '',
      };
      final newCard = await LocalContextService().generateCardForChunk(
        documentId,
        chunk,
        sequence,
      );
      if (newCard != null) {
        if (!kIsWeb) {
          await LocalDatabase.instance.insertCards([newCard]);
        }
        List citations = [];
        if (newCard['citations_json'] != null) {
          try {
            citations = jsonDecode(newCard['citations_json'] as String) as List;
          } catch (e) {
            debugPrint('Athena caught error: $e');
          }
        }
        return {
          'type': 'context_card',
          'id': newCard['id'],
          'insert_after': chunkId,
          'sequence': sequence,
          'title': newCard['title'] ?? '',
          'body': newCard['body'] ?? '',
          'why_here': newCard['why_here'] ?? '',
          'exact_quote': newCard['exact_quote'],
          'support_status': newCard['support_status'] ?? 'fully_supported',
          'generation_mode': newCard['generation_mode'] ?? 'grounded',
          'saved': false,
          'citations': citations,
        };
      }
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    return null;
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
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> fetchVibeCheck(
    String docId,
    int chunkIndex, {
    String? chunkId,
    int? feedIndex,
  }) async {
    if (_hasReachableBackend) {
      try {
        final payload = <String, dynamic>{
          'chunk_index': chunkIndex,
        };
        if (chunkId != null) payload['chunk_id'] = chunkId;
        if (feedIndex != null) payload['feed_index'] = feedIndex;

        final response = await dio.post(
          '/api/documents/$docId/vibe-check',
          data: payload,
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 8),
          ),
        );
        return response.data as Map<String, dynamic>;
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // BYOK LLM routing for all 10 providers with automatic failover
    if (!kIsWeb) {
      try {
        final chunk = chunkId != null
            ? await LocalDatabase.instance.getChunkById(chunkId)
            : (chunkIndex > 0
                ? await LocalDatabase.instance.getChunkBySequence(docId, chunkIndex)
                : null);
        final passage = chunk?['raw_text']?.toString() ?? '';
        if (passage.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final primaryProvider =
              prefs.getString('athena_ai_primary_provider') ?? 'gemini';
          final primaryKey = await SecureStorageService.instance
                  .getAIKey('athena_ai_primary_api_key') ??
              '';
          var primaryModel = prefs.getString('athena_ai_primary_model') ?? '';
          final primaryBaseUrl = prefs.getString('athena_ai_primary_base_url');

          if (primaryKey.trim().isNotEmpty) {
            if (primaryModel.isEmpty) {
              final available = await fetchModels(
                provider: primaryProvider,
                apiKey: primaryKey,
                baseUrl: primaryBaseUrl,
              );
              if (available.isNotEmpty) primaryModel = available.first.id;
            }

            final prompt =
                'You are Athena, a thoughtful literary reading companion.\n'
                'Analyze this passage:\n"$passage"\n\n'
                'Respond with ONLY a JSON object in this format:\n'
                '{\n'
                '  "plain_take": "The core takeaway in 1–2 direct, clear sentences without academic jargon.",\n'
                '  "analogy": "A brief, vivid real-world analogy illuminating the core concept."\n'
                '}';

            var result = await _callLlmChat(
              provider: primaryProvider,
              key: primaryKey.trim(),
              model: primaryModel,
              baseUrl: primaryBaseUrl,
              prompt: prompt,
            );

            // Failover to secondary/fallback provider if primary rate limited or network error
            if (result['status'] == 'rate_limited' || result['status'] == 'network_error') {
              final fallbackKey = await SecureStorageService.instance
                      .getAIKey('athena_ai_fallback_api_key') ??
                  await SecureStorageService.instance
                      .getAIKey('athena_ai_secondary_api_key') ??
                  '';
              if (fallbackKey.trim().isNotEmpty) {
                final fallbackProvider =
                    prefs.getString('athena_ai_fallback_provider') ??
                    prefs.getString('athena_ai_secondary_provider') ??
                    'groq';
                var fallbackModel =
                    prefs.getString('athena_ai_fallback_model') ??
                    prefs.getString('athena_ai_secondary_model') ??
                    '';
                final fallbackBaseUrl =
                    prefs.getString('athena_ai_fallback_base_url') ??
                    prefs.getString('athena_ai_secondary_base_url');

                if (fallbackModel.isEmpty) {
                  final fbModels = await fetchModels(
                    provider: fallbackProvider,
                    apiKey: fallbackKey,
                    baseUrl: fallbackBaseUrl,
                  );
                  if (fbModels.isNotEmpty) fallbackModel = fbModels.first.id;
                }

                if (fallbackModel.isNotEmpty) {
                  final fbResult = await _callLlmChat(
                    provider: fallbackProvider,
                    key: fallbackKey.trim(),
                    model: fallbackModel,
                    baseUrl: fallbackBaseUrl,
                    prompt: prompt,
                  );
                  if (fbResult['status'] == 'ok') {
                    result = fbResult;
                  }
                }
              }
            }

            if (result['status'] == 'ok' && result['answer'] != null) {
              final answer = result['answer'].toString().trim();
              String plainTake = answer;
              String? analogy;

              try {
                final jsonStr = answer
                    .replaceAll(RegExp(r'^```json\s*|^```\s*|```$', multiLine: true), '')
                    .trim();
                final parsed = jsonDecode(jsonStr);
                if (parsed is Map) {
                  if (parsed['plain_take'] != null) plainTake = parsed['plain_take'].toString();
                  if (parsed['analogy'] != null) analogy = parsed['analogy'].toString();
                }
              } catch (e) {
                debugPrint('[Athena] fetchVibeCheck JSON parse notice: $e');
              }

              return {
                'chunk_index': chunkIndex,
                'plain_take': plainTake,
                'simplified': plainTake,
                'analogy': analogy,
                'fallback': false,
                'vibe': 'Key Insight',
                'summary': plainTake,
                'source': 'direct_llm',
              };
            }
          }
        }
      } catch (e) {
        debugPrint('[Athena Plain Take BYOK notice] $e');
      }
    }

    return {
      'chunk_index': chunkIndex,
      'plain_take': "A foundational turning point in the author's thesis.",
      'simplified': "A foundational turning point in the author's thesis.",
      'analogy': null,
      'fallback': true,
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
    if (!kIsWeb) {
      try {
        final document = await LocalDatabase.instance.getDocument(documentId);
        final effectiveDocumentTitle =
            (documentTitle?.trim().isNotEmpty ?? false)
                ? documentTitle!.trim()
                : document?['title']?.toString() ?? 'Document';
        final chunk = await LocalDatabase.instance.getChunk(chunkId);
        final pages = chunk?['source_pages_json']?.toString();
        String pageReference = 'Saved passage';
        if (pages != null) {
          try {
            final decoded = jsonDecode(pages) as List;
            if (decoded.length == 1) pageReference = 'Page ${decoded.first}';
            if (decoded.length > 1) {
              pageReference = 'Pages ${decoded.first}–${decoded.last}';
            }
          } catch (e) {
            debugPrint('Athena quote page reference notice: $e');
          }
        }
        await LocalDatabase.instance.saveQuote({
          'id': id,
          'document_id': documentId,
          'document_title': effectiveDocumentTitle,
          'chunk_id': chunkId,
          'page_reference': pageReference,
          'text': exactQuote ?? quoteText,
          'note': title,
          'created_at': DateTime.now().toIso8601String(),
        });
      } catch (e) {
        debugPrint('Athena local quote save failed: $e');
        rethrow;
      }
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
          'document_title': documentTitle ?? 'Document',
        });
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }

    // 2. Remove from LocalDatabase
    try {
      await LocalDatabase.instance.setCardSaved(id, false);
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }

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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    try {
      await LocalDatabase.instance.clearAllSavedCards();
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }
    if (AppConfig.apiBaseUrl.isNotEmpty) {
      try {
        final list = await getSavedCards();
        for (final item in list) {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            await dio.delete('/api/cards/$id/save');
          }
        }
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
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
        final quotes = await LocalDatabase.instance.getSavedQuotes();
        for (final quote in quotes) {
          if (result.any((item) => item['id'] == quote['id'])) continue;
          final chunk = await LocalDatabase.instance
              .getChunk(quote['chunk_id']?.toString() ?? '');
          int sequence = (chunk?['sequence'] as num?)?.toInt() ?? 1;
          result.add({
            'id': quote['id'],
            'document_id': quote['document_id'],
            'document_title': quote['document_title'],
            'chunk_id': quote['chunk_id'],
            'sequence': sequence,
            'page_reference': quote['page_reference'],
            'card_type': 'user_highlight',
            'title': quote['note'] ?? 'Saved passage',
            'body': quote['text'],
            'citations': <dynamic>[],
          });
        }
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
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
    } catch (e) {
      debugPrint('Athena caught error: $e');
    }

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
      } catch (e) {
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
    if (_hasReachableBackend) {
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
        if (data['status'] == 'ok' ||
            (answer != null && answer.trim().isNotEmpty)) {
          return {
            'status': 'ok',
            'answer': answer,
            'citations': data['citations'] ?? [],
            'source': 'backend',
          };
        }
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // 2. Fetch passage text from LocalDatabase if needed
    var textForPrompt = passageText ?? selectedText ?? '';
    if (textForPrompt.isEmpty && !kIsWeb) {
      try {
        final chunk = await LocalDatabase.instance.getChunk(chunkId);
        if (chunk != null) {
          textForPrompt = chunk['raw_text']?.toString() ?? '';
        }
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // 3. On-device fallback via configured AI key directly over HTTPS
    try {
      final prefs = await SharedPreferences.getInstance();
      final primaryKey = await SecureStorageService.instance
              .getAIKey('athena_ai_primary_api_key') ??
          '';
      final primaryProvider =
          prefs.getString('athena_ai_primary_provider') ?? 'gemini';
      var primaryModel = prefs.getString('athena_ai_primary_model') ?? '';
      final primaryBaseUrl = prefs.getString('athena_ai_primary_base_url');

      if (primaryKey.trim().isEmpty) {
        return {
          'status': 'no_key',
          'message':
              'Passage inquiry needs an API key. Configure your preferred AI engine in Settings.',
        };
      }

      if (primaryModel.isEmpty) {
        final availableModels = await fetchModels(
          provider: primaryProvider,
          apiKey: primaryKey,
          baseUrl: primaryBaseUrl,
        );
        if (availableModels.isNotEmpty) primaryModel = availableModels.first.id;
      }

      final prompt =
          'You are Athena, a thoughtful literary reading companion.\n'
          '${selectedText != null ? "Selected Context: $selectedText\n\n" : (textForPrompt.isNotEmpty ? "Passage: $textForPrompt\n\n" : "")}'
          'User Question: $question\n\n'
          'Please provide a clear, concise (under 120 words), insightful explanation directly answering the question.';

      var result = await _callLlmChat(
        provider: primaryProvider,
        key: primaryKey.trim(),
        model: primaryModel,
        baseUrl: primaryBaseUrl,
        prompt: prompt,
      );

      // If primary failed with 429 or 5xx/network error, automatically retry with configured fallback provider
      if (result['status'] == 'rate_limited' ||
          result['status'] == 'network_error') {
        final fallbackKey = await SecureStorageService.instance
                .getAIKey('athena_ai_fallback_api_key') ??
            await SecureStorageService.instance
                .getAIKey('athena_ai_secondary_api_key') ??
            '';
        if (fallbackKey.trim().isNotEmpty) {
          final fallbackProvider =
              prefs.getString('athena_ai_fallback_provider') ??
              prefs.getString('athena_ai_secondary_provider') ??
              'groq';
          var fallbackModel =
              prefs.getString('athena_ai_fallback_model') ??
              prefs.getString('athena_ai_secondary_model') ??
              '';
          final fallbackBaseUrl =
              prefs.getString('athena_ai_fallback_base_url') ??
              prefs.getString('athena_ai_secondary_base_url');

          if (fallbackModel.isEmpty) {
            final fbModels = await fetchModels(
              provider: fallbackProvider,
              apiKey: fallbackKey,
              baseUrl: fallbackBaseUrl,
            );
            if (fbModels.isNotEmpty) fallbackModel = fbModels.first.id;
          }

          if (fallbackModel.isNotEmpty) {
            final fbResult = await _callLlmChat(
              provider: fallbackProvider,
              key: fallbackKey.trim(),
              model: fallbackModel,
              baseUrl: fallbackBaseUrl,
              prompt: prompt,
            );
            if (fbResult['status'] == 'ok') {
              return fbResult;
            }
          }
        }
      }

      return result;
    } catch (e) {
      return {
        'status': 'network_error',
        'message': 'Failed to process inquiry: $e',
      };
    }
  }

  Future<Map<String, dynamic>> _callLlmChat({
    required String provider,
    required String key,
    required String model,
    String? baseUrl,
    required String prompt,
  }) async {
    final client = Dio();
    try {
      if (provider == 'gemini') {
        final cleanModel = model.replaceFirst(RegExp(r'^models/'), '');
        if (cleanModel.isEmpty) {
          return {
            'status': 'no_key',
            'message': 'No live Gemini model selected in Settings.'
          };
        }
        final url =
            'https://generativelanguage.googleapis.com/v1beta/models/$cleanModel:generateContent';
        final resp = await client.post(
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
          options: Options(
            headers: {
              'x-goog-api-key': key,
              'Content-Type': 'application/json',
            },
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        if (resp.statusCode == 200 && resp.data is Map) {
          final cand = (resp.data['candidates'] as List?)?.firstOrNull;
          final part = (cand?['content']?['parts'] as List?)?.firstOrNull;
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
      } else if (provider == 'anthropic') {
        if (model.isEmpty) {
          return {
            'status': 'no_key',
            'message': 'No live Anthropic model selected in Settings.'
          };
        }
        final resp = await client.post(
          'https://api.anthropic.com/v1/messages',
          data: {
            'model': model,
            'max_tokens': 300,
            'messages': [
              {'role': 'user', 'content': prompt}
            ],
          },
          options: Options(
            headers: {
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
            },
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        if (resp.statusCode == 200 && resp.data is Map) {
          final content = (resp.data['content'] as List?)?.firstOrNull;
          final answer =
              content is Map ? content['text']?.toString() ?? '' : '';
          if (answer.trim().isNotEmpty) {
            return {
              'status': 'ok',
              'answer': answer.trim(),
              'citations': [],
              'source': 'direct_anthropic',
            };
          }
        }
      } else {
        // OpenAI-compatible providers: groq, deepseek, openrouter, openai, mistral, together, nvidia, custom
        String compUrl;
        if (provider == 'groq') {
          compUrl = 'https://api.groq.com/openai/v1/chat/completions';
        } else if (provider == 'openai') {
          compUrl = 'https://api.openai.com/v1/chat/completions';
        } else if (provider == 'openrouter') {
          compUrl = 'https://openrouter.ai/api/v1/chat/completions';
        } else if (provider == 'deepseek') {
          compUrl = 'https://api.deepseek.com/v1/chat/completions';
        } else if (provider == 'mistral') {
          compUrl = 'https://api.mistral.ai/v1/chat/completions';
        } else if (provider == 'together') {
          compUrl = 'https://api.together.xyz/v1/chat/completions';
        } else if (provider == 'nvidia') {
          compUrl = 'https://integrate.api.nvidia.com/v1/chat/completions';
        } else if (provider == 'custom') {
          final cleanBase = (baseUrl ?? '').trim();
          if (cleanBase.isEmpty) {
            throw const AppError(
              code: 'INVALID_CONFIG',
              message: 'Custom provider requires a valid Base URL',
            );
          }
          final b = sanitizeProviderUrl(cleanBase);
          compUrl = b.endsWith('/chat/completions') ? b : '$b/chat/completions';
        } else {
          throw AppError(
            code: 'UNSUPPORTED_PROVIDER',
            message: 'Unsupported provider configuration: $provider',
          );
        }

        if (model.isEmpty) {
          return {
            'status': 'no_key',
            'message': 'Select a live model in Settings before asking.'
          };
        }

        final resp = await client.post(
          compUrl,
          data: {
            'model': model,
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
    } on DioException catch (de) {
      final code = de.response?.statusCode;
      if (code == 401 || code == 403) {
        return {
          'status': 'auth_error',
          'message': 'API key was rejected ($code). Please check Settings.'
        };
      } else if (code == 429) {
        return {
          'status': 'rate_limited',
          'message': 'Rate limit exceeded (429).'
        };
      } else if (code != null && code >= 500) {
        return {
          'status': 'network_error',
          'message': 'AI provider server error ($code).'
        };
      }
      return {
        'status': 'network_error',
        'message': de.message ?? 'Network request failed.'
      };
    } catch (e) {
      return {'status': 'network_error', 'message': e.toString()};
    }
    return {
      'status': 'network_error',
      'message': 'Failed to obtain an answer from the AI provider.'
    };
  }

  // --- BYOK Multi-Provider AI Settings ---

  Future<AIConfig> getAIConfig() async {
    if (_hasReachableBackend) {
      try {
        final response = await dio
            .get('/api/settings/ai-config')
            .timeout(const Duration(seconds: 2));
        final cfg = AIConfig.fromJson(response.data as Map<String, dynamic>);
        if (cfg.isConfigured) return cfg;
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // Read from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final pKey = await SecureStorageService.instance
        .getAIKey('athena_ai_primary_api_key');
    final pProv = prefs.getString('athena_ai_primary_provider') ?? 'gemini';
    final pModel = prefs.getString('athena_ai_primary_model') ?? '';
    final pBase = prefs.getString('athena_ai_primary_base_url');
    final fKey = await SecureStorageService.instance
        .getAIKey('athena_ai_fallback_api_key');
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
    // Provider settings are non-secret; credentials are kept in OS secure storage.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('athena_ai_primary_provider', primaryProvider);
    if (primaryApiKey != null && !primaryApiKey.contains('...')) {
      await SecureStorageService.instance
          .setAIKey('athena_ai_primary_api_key', primaryApiKey);
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
      await SecureStorageService.instance
          .setAIKey('athena_ai_fallback_api_key', fallbackApiKey);
    }
    if (fallbackModel != null && fallbackModel.isNotEmpty) {
      await prefs.setString('athena_ai_fallback_model', fallbackModel);
    }
    if (fallbackBaseUrl != null) {
      await prefs.setString('athena_ai_fallback_base_url', fallbackBaseUrl);
    }

    // 2. Try companion backend, if unreachable, do not throw
    if (_hasReachableBackend) {
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
          options: Options(
            sendTimeout: const Duration(seconds: 3),
            receiveTimeout: const Duration(seconds: 4),
          ),
        );
        return response.data as Map<String, dynamic>;
      } catch (e) {
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
    final cleanKey = (apiKey ?? '').trim();

    if (pKey != 'custom' && (cleanKey.isEmpty || cleanKey.contains('...'))) {
      return const [];
    }

    // 1. Try companion backend
    if (_hasReachableBackend && kIsWeb) {
      try {
        final response = await dio.post(
          '/api/settings/fetch-models',
          data: {
            'provider': provider,
            if (cleanKey.isNotEmpty) 'api_key': cleanKey,
            if (baseUrl != null) 'base_url': baseUrl,
          },
          options: Options(
            sendTimeout: const Duration(seconds: 4),
            receiveTimeout: const Duration(seconds: 6),
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
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
    }

    // 2. Direct on-device models discovery for Gemini
    if (pKey == 'gemini') {
      try {
        final client = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 6),
        ));
        final mResp = await client.get(
          'https://generativelanguage.googleapis.com/v1beta/models',
          options: Options(headers: {
            'Accept': 'application/json',
            'x-goog-api-key': cleanKey,
          }),
        );
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
      } catch (e) {
        debugPrint('Athena caught error: $e');
      }
      return const [];
    }

    // 3. Direct on-device models discovery for other providers
    final res = await directTestProvider(
      provider: provider,
      apiKey: cleanKey,
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

    return const [];
  }

  static Future<Map<String, dynamic>> directTestProvider({
    required String provider,
    String? apiKey,
    String? model,
    String? baseUrl,
    Dio? httpClient,
  }) async {
    final key = (apiKey ?? '').trim();
    final providerKey = provider.toLowerCase();
    if (key.isEmpty && providerKey != 'custom') {
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': 0,
        'message': 'API key is required to test connection',
        'models': <Map<String, dynamic>>[]
      };
    }

    final timer = Stopwatch()..start();
    final client = httpClient ??
        Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 6),
          receiveTimeout: const Duration(seconds: 8),
        ));
    try {
      late final String modelsUrl;
      late final Map<String, dynamic> headers;
      if (providerKey == 'gemini') {
        modelsUrl = 'https://generativelanguage.googleapis.com/v1beta/models';
        headers = {
          'Accept': 'application/json',
          'x-goog-api-key': key,
        };
      } else if (providerKey == 'anthropic') {
        modelsUrl = 'https://api.anthropic.com/v1/models';
        headers = {
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
          'Accept': 'application/json'
        };
      } else {
        final rawRoot = switch (providerKey) {
          'groq' => 'https://api.groq.com/openai/v1',
          'openai' => 'https://api.openai.com/v1',
          'openrouter' => 'https://openrouter.ai/api/v1',
          'deepseek' => 'https://api.deepseek.com/v1',
          'mistral' => 'https://api.mistral.ai/v1',
          'together' => 'https://api.together.xyz/v1',
          'nvidia' => 'https://integrate.api.nvidia.com/v1',
          'custom' => sanitizeProviderUrl(baseUrl ?? ''),
          _ => throw AppError(
            code: 'UNSUPPORTED_PROVIDER',
            message: 'Unsupported provider configuration: $providerKey',
          ),
        };
        if (providerKey == 'custom' && rawRoot.isEmpty) {
          return {
            'ok': false,
            'valid': false,
            'status': 'error',
            'latency_ms': 0,
            'message': 'Custom provider requires a valid Base URL',
            'models': <Map<String, dynamic>>[]
          };
        }
        final root = sanitizeProviderUrl(rawRoot);
        modelsUrl = root.endsWith('/models') ? root : '$root/models';
        headers = {
          'Accept': 'application/json',
          if (key.isNotEmpty) 'Authorization': 'Bearer $key'
        };
      }

      // A successful live model listing verifies the credential. Do not send a
      // generation request here: providers can reject an empty or stale model.
      final response =
          await client.get(modelsUrl, options: Options(headers: headers));
      final raw = response.data is Map
          ? ((response.data['models'] as List?) ??
              (response.data['data'] as List?) ??
              [])
          : (response.data is List ? response.data as List : <dynamic>[]);
      final models = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        if (providerKey == 'gemini') {
          final methods =
              (item['supportedGenerationMethods'] as List?) ?? const [];
          if (methods.isNotEmpty && !methods.contains('generateContent')) {
            continue;
          }
        }
        var id = item['id']?.toString() ?? item['name']?.toString() ?? '';
        if (providerKey == 'gemini' && id.startsWith('models/')) {
          id = id.substring(7);
        }
        if (id.isEmpty) continue;
        final lower = id.toLowerCase();
        if (lower.contains('embedding') ||
            lower.contains('whisper') ||
            lower.contains('tts') ||
            lower.contains('dall-e') ||
            lower.contains('imagen') ||
            lower.contains('aqa')) {
          continue;
        }
        models.add({
          'id': id,
          'name':
              item['display_name'] ?? item['displayName'] ?? item['name'] ?? id
        });
      }
      timer.stop();
      return {
        'ok': true,
        'valid': true,
        'status': 'success',
        'latency_ms': timer.elapsedMilliseconds,
        'message': models.isEmpty
            ? 'Provider responded, but listed no compatible models.'
            : 'Connection verified; loaded ${models.length} models.',
        'models': models,
      };
    } on DioException catch (error) {
      timer.stop();
      final payload = error.response?.data;
      final detail = payload is Map
          ? (payload['error'] is Map
              ? payload['error']['message']?.toString()
              : payload['message']?.toString())
          : null;
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': timer.elapsedMilliseconds,
        'message': detail ?? error.message ?? 'Provider connection failed.',
        'models': <Map<String, dynamic>>[]
      };
    } catch (error) {
      timer.stop();
      return {
        'ok': false,
        'valid': false,
        'status': 'error',
        'latency_ms': timer.elapsedMilliseconds,
        'message': error.toString(),
        'models': <Map<String, dynamic>>[]
      };
    }
  }

  Future<Map<String, dynamic>> testAIConnection({
    required String provider,
    String? apiKey,
    String? model,
    String? baseUrl,
  }) async {
    final cleanKey = (apiKey ?? '').trim();

    // 1. Try companion engine backend first if configured and reachable
    if (_hasReachableBackend && kIsWeb) {
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
      } catch (e) {
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

  // --- Security & LAN Companion Pairing (F29, F30) ---

  /// Checks whether cleartext HTTP is allowed for a given host URL.
  /// Cleartext HTTP is strictly forbidden for external cloud domains and only permitted
  /// for loopback (127.0.0.1, localhost) or private RFC1918 LAN networks
  /// (192.168.x.x, 10.x.x.x, 172.16-31.x.x, *.local).
  static bool isPermittedHttpHost(String url) {
    return AppConfig.isPermittedHttpUrl(url);
  }

  /// Sanitizes AI provider base URLs and enforces HTTPS for all cloud endpoints.
  static String sanitizeProviderUrl(String url) {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) return clean;
    final uri = Uri.tryParse(clean);
    if (uri == null) return clean;
    final host = uri.host.toLowerCase();
    const externalCloudHosts = {
      'googleapis.com',
      'openai.com',
      'anthropic.com',
      'openrouter.ai',
      'groq.com',
      'deepseek.com',
    };
    final isCloud = externalCloudHosts.any((ch) => host == ch || host.endsWith('.$ch'));
    if (isCloud && uri.scheme != 'https') {
      return uri.replace(scheme: 'https').toString();
    }
    if (uri.scheme == 'http' && !isPermittedHttpHost(clean)) {
      return uri.replace(scheme: 'https').toString();
    }
    return clean;
  }

  /// Verifies connectivity to the desktop companion server on Wi-Fi or LAN.
  Future<Map<String, dynamic>> testServerConnection({
    String? serverUrl,
    String? pairingToken,
  }) async {
    final targetUrl = (serverUrl ?? AppConfig.apiBaseUrl).trim().replaceAll(RegExp(r'/+$'), '');
    if (targetUrl.isEmpty) {
      return {
        'ok': false,
        'code': 'EMPTY_URL',
        'message': 'Server URL is empty. Athena is operating in standalone mobile mode.',
      };
    }
    final uri = Uri.tryParse(targetUrl);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return {
        'ok': false,
        'code': 'INVALID_URL',
        'message': 'Invalid URL scheme. Must begin with http:// or https://',
      };
    }
    if (uri.isScheme('http') && !isPermittedHttpHost(targetUrl)) {
      return {
        'ok': false,
        'code': 'CLEARTEXT_NOT_PERMITTED',
        'message': 'Cleartext HTTP is only allowed for private LAN IPs (192.168.x.x, 10.x.x.x, *.local) or loopback.',
      };
    }

    final token = (pairingToken ?? AppConfig.pairingToken).trim();
    final testDio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
    ));

    try {
      final response = await testDio.get(
        '$targetUrl/api/health',
        options: Options(
          headers: {
            'Accept': 'application/json',
            if (token.isNotEmpty) 'X-Athena-Pairing-Token': token,
          },
        ),
      );
      if (response.statusCode == 200) {
        if (token.isNotEmpty) {
          try {
            await testDio.get(
              '$targetUrl/api/settings/ai-config',
              options: Options(
                headers: {
                  'Accept': 'application/json',
                  'X-Athena-Pairing-Token': token,
                },
              ),
            );
          } on DioException catch (authErr) {
            if (authErr.response?.statusCode == 401 ||
                authErr.response?.statusCode == 403) {
              return {
                'ok': false,
                'code': 'INVALID_PAIRING_TOKEN',
                'message':
                    'Pairing token rejected (${authErr.response?.statusCode}). Enter the Pairing Token shown in your desktop terminal.',
              };
            }
          }
        }
        final data = response.data is Map ? response.data as Map : {};
        final isConfigured = data['llm_configured'] == true;
        return {
          'ok': true,
          'message': isConfigured
              ? 'Connected to Companion Server ($targetUrl).'
              : 'Companion Connected · AI Not Configured',
          'data': response.data,
        };
      }
      return {
        'ok': false,
        'code': 'HTTP_${response.statusCode}',
        'message': 'Server returned HTTP ${response.statusCode}: ${response.statusMessage}',
      };
    } on DioException catch (e) {
      String code = 'NETWORK_ERROR';
      String msg;
      if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.connectionError) {
        code = 'CONNECTION_TIMED_OUT';
        msg = 'Connection refused or timed out at $targetUrl. Verify desktop server is running and phone is on the same Wi-Fi.';
      } else if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        code = 'INVALID_PAIRING_TOKEN';
        msg = 'Pairing token rejected (HTTP ${e.response?.statusCode}). Enter the Pairing Token shown in your desktop terminal.';
      } else {
        msg = e.message ?? 'Unknown connection error';
      }
      return {
        'ok': false,
        'code': code,
        'message': msg,
      };
    } catch (e) {
      return {
        'ok': false,
        'code': 'UNKNOWN',
        'message': 'Connection test failed: $e',
      };
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
