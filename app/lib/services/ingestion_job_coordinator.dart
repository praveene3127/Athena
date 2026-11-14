import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/services/local_context_service.dart';

/// Single-flight coordinator for document ingestion, checkpoint resumability,
/// and Android foreground service lifecycle.
class IngestionJobCoordinator {
  IngestionJobCoordinator._() {
    _fgChannel.setMethodCallHandler(_handleMethodCall);
    _legacyChannel.setMethodCallHandler(_handleMethodCall);
  }

  static final IngestionJobCoordinator instance = IngestionJobCoordinator._();

  static const MethodChannel _fgChannel =
      MethodChannel('athena/foreground_ingestion');
  static const MethodChannel _legacyChannel =
      MethodChannel('com.athena.reading/foreground_service');

  final Set<String> _activeDocIds = <String>{};
  final Set<String> _cancelledDocIds = <String>{};
  DateTime _lastNotificationUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  bool isJobActive(String docId) => _activeDocIds.contains(docId);
  bool isJobCancelled(String docId) => _cancelledDocIds.contains(docId);

  Set<String> get activeDocIds => Set.unmodifiable(_activeDocIds);

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onForegroundTimeout') {
      debugPrint('[Athena Coordinator] Received onForegroundTimeout from Android OS');
      await _handleTimeout();
    }
  }

  Future<void> _handleTimeout() async {
    final activeIds = List<String>.from(_activeDocIds);
    for (final docId in activeIds) {
      await cancelJob(docId, markStatus: 'paused', reason: 'Foreground service timed out');
    }
  }

  /// Cancels an active ingestion job, cleans up active state and foreground service.
  Future<void> cancelJob(String docId, {String markStatus = 'paused', String? reason}) async {
    _cancelledDocIds.add(docId);
    _activeDocIds.remove(docId);
    try {
      final db = await LocalDatabase.instance.database;
      await db.update(
        'documents',
        {
          'status': markStatus,
          'stage': markStatus,
          'stage_label': reason ?? 'Ingestion paused',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [docId],
      );
    } catch (e) {
      debugPrint('[Athena Coordinator] cancelJob error: $e');
    }
    if (_activeDocIds.isEmpty) {
      await _stopForeground();
    }
  }

  /// Run startup recovery ONCE in main() before runApp.
  /// Any interrupted or stalled jobs are safely marked 'paused' preserving all committed chunks.
  Future<void> recoverStartupJobs() async {
    if (kIsWeb) return;
    try {
      final db = await LocalDatabase.instance.database;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final staleDocs = await db.query(
        'documents',
        columns: [
          'id',
          'status',
          'last_checkpoint_page',
          'page_count',
          'heartbeat_at'
        ],
        where: "status IN ('processing', 'queued', 'partially_readable')",
      );
      for (final doc in staleDocs) {
        final docId = doc['id'] as String;
        if (isJobActive(docId)) continue;
        final heartbeat = (doc['heartbeat_at'] as num?)?.toInt() ?? 0;
        final isStale = (nowMs - heartbeat) > 30000;
        if (!isStale) continue;

        final checkpoint = (doc['last_checkpoint_page'] as num?)?.toInt() ?? 0;
        final status = checkpoint > 0 ? 'paused' : 'interrupted';
        await db.update(
          'documents',
          {
            'status': status,
            'stage': 'paused',
            'stage_label': checkpoint > 0
                ? 'Paused at page $checkpoint'
                : 'Ingestion interrupted',
            'error_code': 'EXTRACTION_INTERRUPTED',
            'error_message':
                'Ingestion was interrupted. Tap Continue to resume.',
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [docId],
        );
      }
    } catch (e) {
      debugPrint('[Athena Coordinator] recoverStartupJobs error: $e');
    }
  }

  Future<void> _invokeChannel(String method, [dynamic arguments]) async {
    if (kIsWeb) return;
    try {
      await _fgChannel.invokeMethod(method, arguments);
    } on MissingPluginException {
      try {
        await _legacyChannel.invokeMethod(method, arguments);
      } on MissingPluginException catch (e) {
        debugPrint('[Athena Coordinator] $method notice: ${e.message}');
      }
    } on PlatformException catch (e) {
      if (e.code == 'notImplemented') {
        debugPrint('[Athena Coordinator] $method not implemented');
      } else {
        rethrow;
      }
    }
  }

  Future<void> requestNotificationPermission() =>
      _invokeChannel('requestNotificationPermission');

  Future<void> _startForeground(String title) =>
      _invokeChannel('startForegroundService', {'title': title});

  Future<void> updateForegroundProgress({
    required String title,
    required int page,
    required int total,
    required int percent,
  }) async {
    if (kIsWeb) return;
    final now = DateTime.now();
    if (now.difference(_lastNotificationUpdate).inMilliseconds < 1000 &&
        percent != 100 &&
        percent != 0) {
      return;
    }
    _lastNotificationUpdate = now;
    await _invokeChannel('updateForegroundProgress', {
      'title': title,
      'page': page,
      'total': total,
      'percent': percent,
    });
  }

  Future<void> _stopForeground() =>
      _invokeChannel('stopForegroundService');

  /// Start a new ingestion or resume an unfinished/paused/interrupted document from its checkpoint.
  /// If redoFromScratch is true, clears committed chunks and restarts from page 1.
  /// Otherwise preserves 100% of committed chunks and resumes at last_checkpoint_page + 1.
  Future<String> startOrResume(
    String docId, {
    bool redoFromScratch = false,
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (isJobActive(docId)) {
      debugPrint('[Athena Coordinator] Job already active for $docId');
      return docId;
    }

    _cancelledDocIds.remove(docId);
    _activeDocIds.add(docId);

    try {
      if (redoFromScratch) {
        await LocalDatabase.instance.clearDocumentContent(docId);
        final db = await LocalDatabase.instance.database;
        await db.update(
          'documents',
          {
            'last_checkpoint_page': 0,
            'last_chunk_sequence': 0,
            'last_char_offset': 0,
            'carry_over_text': null,
            'profile_json': null,
            'status': 'queued',
            'percent': 0,
            'processed_page': 0,
            'processed_pages': 0,
          },
          where: 'id = ?',
          whereArgs: [docId],
        );
      }

      final doc = await LocalDatabase.instance.getDocument(docId);
      if (doc == null) {
        throw const AppError(
          code: 'DOC_NOT_FOUND',
          message: 'Document not found in local database.',
        );
      }

      final title = (doc['title'] as String?) ?? 'Document';
      await requestNotificationPermission();
      await _startForeground('Reading $title...');
      final filePath = doc['file_path'] as String?;
      final fileName = doc['filename'] as String? ?? 'document.pdf';
      final totalPages = (doc['page_count'] as num?)?.toInt() ?? 0;
      final lastCheckpointPage =
          (doc['last_checkpoint_page'] as num?)?.toInt() ?? 0;
      final lastChunkSequence =
          (doc['last_chunk_sequence'] as num?)?.toInt() ?? 0;
      final lastCharOffset =
          (doc['last_char_offset'] as num?)?.toInt() ?? 0;
      final carryOverText = doc['carry_over_text'] as String?;
      final profileJson = doc['profile_json'] as String?;

      // Prune any uncommitted tail chunks past the recorded sequence
      await LocalDatabase.instance
          .pruneUncommittedTailChunks(docId, lastChunkSequence);

      final startFromPage = lastCheckpointPage + 1;

      await LocalDatabase.instance.updateDocumentProgress(
        docId,
        status: lastCheckpointPage > 0 ? 'partially_readable' : 'processing',
        stage: 'extracting',
        stageLabel: lastCheckpointPage > 0
            ? 'Resuming from page $startFromPage...'
            : 'Starting extraction...',
      );

      final result = await DocumentIngestionPipeline.ingest(
        docId: docId,
        fileName: fileName,
        filePath: filePath,
        startFromPage: startFromPage,
        initialSequence: lastChunkSequence + 1,
        initialOffset: lastCharOffset,
        initialCarryOver: carryOverText,
        savedProfileJson: profileJson,
        onProgress: (p, s) {
          onProgress?.call(p, s);
        },
        onBatch: (batchChunks, processedPages, totalPagesCount, isFinalBatch, {
          int? lastSequence,
          int? lastCharOffset,
          String? carryOverText,
          String? profileJson,
        }) async {
          await LocalDatabase.instance.insertChunksBatch(
            batchChunks,
            documentId: docId,
            checkpointPage: processedPages,
            chunkSequence: lastSequence ?? 0,
            charOffset: lastCharOffset ?? 0,
            carryOverText: carryOverText,
            profileJson: profileJson,
            isFinalBatch: isFinalBatch,
          );

          final denom = totalPagesCount <= 0 ? 1 : totalPagesCount;
          final pct = (5 + ((processedPages / denom) * 90)).round().clamp(5, 95);
          final stageMsg =
              'Extracting pages $processedPages of $totalPagesCount ($pct%)...';

          await updateForegroundProgress(
            title: title,
            page: processedPages,
            total: totalPagesCount,
            percent: pct,
          );

          await LocalDatabase.instance.updateDocumentProgress(
            docId,
            status: processedPages >= 16 ? 'partially_readable' : 'processing',
            stage: 'extracting',
            stageLabel: stageMsg,
            percent: pct,
            processedPage: processedPages,
            pageCount: totalPagesCount,
          );
        },
      );

      // Finalize document upon completion
      final finalPageCount =
          result.pageCount > 0 ? result.pageCount : totalPages;
      final stats = await LocalDatabase.instance.computeDocumentStats(docId);
      final finalCanonicalSha =
          await LocalDatabase.instance.computeDocumentCanonicalSha256(docId);
      final readingTime =
          (stats.totalWords / 200).ceil().clamp(1, 9999);

      await updateForegroundProgress(
        title: title,
        page: finalPageCount,
        total: finalPageCount,
        percent: 100,
      );

      await LocalDatabase.instance.updateDocumentProgress(
        docId,
        status: 'ready',
        stage: 'done',
        stageLabel: 'Ready to read',
        percent: 100,
        processedPage: finalPageCount,
        pageCount: finalPageCount,
        totalWords: stats.totalWords,
        totalCharacters: stats.totalCharacters,
        readingTimeMinutes: readingTime,
        canonicalSha256: finalCanonicalSha,
        integrityVerified: 1,
      );

      // Fast initial extractive notes (<= 8 cards, < 20ms)
      try {
        final fastChunks = await LocalDatabase.instance.getChunks(docId, limit: 16);
        if (fastChunks.isNotEmpty) {
          final contextService = LocalContextService();
          final fastCards = await contextService.buildFastInitialExtractiveCards(
            docId,
            fastChunks,
            maxCards: 8,
          );
          if (fastCards.isNotEmpty) {
            await LocalDatabase.instance.insertCards(fastCards);
          }
        }
      } catch (e) {
        debugPrint('[Athena Coordinator] fast cards notice: $e');
      }

      onProgress?.call(1.0, 'Ready to read');
      return docId;
    } catch (e) {
      if (isJobCancelled(docId)) {
        debugPrint('[Athena Coordinator] Ingestion cancelled cleanly for $docId');
        return docId;
      }
      debugPrint('[Athena Coordinator] Ingestion failed: $e');
      final appErr = AppError.fromException(e);
      await LocalDatabase.instance.updateDocumentProgress(
        docId,
        status: 'failed',
        stage: 'failed',
        stageLabel: appErr.message,
        errorMessage: appErr.message,
        errorCode: appErr.code,
      );
      rethrow;
    } finally {
      _activeDocIds.remove(docId);
      _cancelledDocIds.remove(docId);
      if (_activeDocIds.isEmpty) {
        await _stopForeground();
      }
    }
  }

  /// Continue or resume an unfinished/paused/interrupted document from its checkpoint.
  Future<String> continueDocument(
    String docId, {
    void Function(double progress, String stage)? onProgress,
  }) =>
      startOrResume(docId, redoFromScratch: false, onProgress: onProgress);

  /// Explicit Retry or Redo:
  /// - redoFromScratch == false: Resumes cleanly from checkpoint (never calls clearDocumentContent!)
  /// - redoFromScratch == true: Clears existing content and restarts from page 1 upon user confirmation.
  Future<void> retryDocument(String docId,
          {bool redoFromScratch = false}) =>
      startOrResume(docId, redoFromScratch: redoFromScratch);
}
