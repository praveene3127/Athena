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
  IngestionJobCoordinator._();

  static final IngestionJobCoordinator instance = IngestionJobCoordinator._();

  static const MethodChannel _fgChannel =
      MethodChannel('com.athena.reading/foreground_service');

  final Set<String> _activeDocIds = <String>{};

  bool isJobActive(String docId) => _activeDocIds.contains(docId);

  Set<String> get activeDocIds => Set.unmodifiable(_activeDocIds);

  /// Run startup recovery ONCE in main() before runApp.
  /// Any interrupted jobs are safely marked 'paused' preserving all committed chunks.
  Future<void> recoverStartupJobs() async {
    if (kIsWeb) return;
    try {
      final db = await LocalDatabase.instance.database;
      final staleDocs = await db.query(
        'documents',
        columns: ['id', 'status', 'last_checkpoint_page', 'page_count'],
        where: "status IN ('processing', 'queued')",
      );
      for (final doc in staleDocs) {
        final docId = doc['id'] as String;
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
      debugPrint('[Athena Coordinator] recoverStartupJobs notice: $e');
    }
  }

  Future<void> _startForeground(String title) async {
    if (kIsWeb) return;
    try {
      await _fgChannel.invokeMethod('startForegroundService', {'title': title});
    } catch (e) {
      // Platform channels may not be implemented in unit tests or unsupported OS
      debugPrint('[Athena Coordinator] startForegroundService notice: $e');
    }
  }

  Future<void> _stopForeground() async {
    if (kIsWeb) return;
    try {
      await _fgChannel.invokeMethod('stopForegroundService');
    } catch (e) {
      debugPrint('[Athena Coordinator] stopForegroundService notice: $e');
    }
  }

  /// Continue or resume an unfinished/paused/interrupted document from its checkpoint.
  /// Resumes at last_checkpoint_page + 1 and preserves 100% of committed chunks.
  Future<String> continueDocument(
    String docId, {
    void Function(double progress, String stage)? onProgress,
  }) async {
    if (isJobActive(docId)) {
      debugPrint('[Athena Coordinator] Job already active for $docId');
      return docId;
    }

    final doc = await LocalDatabase.instance.getDocument(docId);
    if (doc == null) {
      throw const AppError(
        code: 'DOC_NOT_FOUND',
        message: 'Document not found in local database.',
      );
    }

    _activeDocIds.add(docId);
    final title = (doc['title'] as String?) ?? 'Document';
    await _startForeground('Reading $title...');

    try {
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
          await LocalDatabase.instance.insertChunksBatchWithCheckpoint(
            batchChunks,
            documentId: docId,
            checkpointPage: processedPages,
            chunkSequence: lastSequence ?? 0,
            charOffset: lastCharOffset ?? 0,
            carryOverText: carryOverText,
            profileJson: profileJson,
            isFinalBatch: isFinalBatch,
          );

          final progressFraction = 0.05 +
              0.65 *
                  (processedPages /
                      (totalPagesCount == 0 ? 1 : totalPagesCount));
          final pctInt = (progressFraction * 100).toInt();
          final stageMsg =
              'Extracting pages $processedPages of $totalPagesCount ($pctInt%)...';

          await LocalDatabase.instance.updateDocumentProgress(
            docId,
            status: processedPages >= 16 ? 'partially_readable' : 'processing',
            stage: 'extracting',
            stageLabel: stageMsg,
            percent: pctInt,
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
      await _stopForeground();
    }
  }

  /// Explicit Retry or Redo:
  /// - redoFromScratch == false: Resumes cleanly from checkpoint (never calls clearDocumentContent!)
  /// - redoFromScratch == true: Clears existing content and restarts from page 1 upon user confirmation.
  Future<void> retryDocument(String docId, {bool redoFromScratch = false}) async {
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
    await continueDocument(docId);
  }
}

