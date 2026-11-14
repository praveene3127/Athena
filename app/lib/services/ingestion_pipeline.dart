import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';
import 'package:cross_file/cross_file.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/models/section_role.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/services/local_database.dart';

class IngestionResult {
  final String canonicalText;
  final String canonicalSha256;
  final int pageCount;
  final List<Map<String, Object?>> chunks;
  final bool integrityVerified;
  final int totalWords;
  final int totalCharacters;
  final int chunkCount;
  final List<Map<String, Object?>> chapters;

  const IngestionResult({
    required this.canonicalText,
    required this.canonicalSha256,
    required this.pageCount,
    required this.chunks,
    required this.integrityVerified,
    this.totalWords = 0,
    this.totalCharacters = 0,
    this.chunkCount = 0,
    this.chapters = const [],
  });
}

class LineFragment {
  final String text;
  final double top;
  final double bottom;
  final double left;
  final double right;
  final double height;
  final double width;
  final double fontSize;
  final double pageHeight;
  final bool isBold;

  LineFragment({
    required this.text,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    double? height,
    double? width,
    this.fontSize = 12.0,
    this.pageHeight = 792.0,
    this.isBold = false,
  })  : height = height ?? (bottom - top).abs(),
        width = width ?? (right - left).abs();
}

class DocumentIngestionPipeline {
  /// Entry point for document ingestion.
  /// Spawns ONE long-lived isolate on mobile/desktop opening PdfDocument ONCE,
  /// streaming processed page batches incrementally back to the caller.
  static Future<IngestionResult> ingest({
    required String docId,
    required String fileName,
    String? filePath,
    List<int>? fileBytes,
    int chunkWindowPages = 16,
    int startFromPage = 1,
    int initialSequence = 1,
    int initialOffset = 0,
    String? initialCarryOver,
    String? savedProfileJson,
    Duration watchdogTimeout = const Duration(seconds: 90),
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch, {
      int? lastSequence,
      int? lastCharOffset,
      String? carryOverText,
      String? profileJson,
    })? onBatch,
  }) async {
    final hasPath =
        filePath != null && filePath.isNotEmpty && !filePath.startsWith('local://');
    final hasBytes = fileBytes != null && fileBytes.isNotEmpty;

    if (!hasPath && !hasBytes) {
      throw const AppError(
        code: 'FILE_NOT_FOUND',
        message: 'No file path or file bytes provided for ingestion.',
      );
    }

    final lowerName = fileName.toLowerCase();

    // 1. Dispatch EPUB
    if (lowerName.endsWith('.epub')) {
      if (kIsWeb) {
        List<int> bytes = fileBytes ?? const [];
        if (bytes.isEmpty && filePath != null && filePath.isNotEmpty) {
          bytes = await XFile(filePath).readAsBytes();
        }
        return _ingestEpubDirect(
          docId: docId,
          fileName: fileName,
          bytes: bytes,
          onProgress: onProgress,
          onBatch: onBatch,
        );
      }
      return _runEpubPipelineWithIsolate(
        docId: docId,
        fileName: fileName,
        filePath: hasPath ? filePath : null,
        fileBytes: hasBytes ? fileBytes : null,
        startFromPage: startFromPage,
        initialSequence: initialSequence,
        initialOffset: initialOffset,
        initialCarryOver: initialCarryOver,
        watchdogTimeout: watchdogTimeout,
        onProgress: onProgress,
        onBatch: onBatch,
      );
    }

    // 2. Dispatch PDF
    if (kIsWeb) {
      List<int> bytes = fileBytes ?? const [];
      if (bytes.isEmpty && filePath != null && filePath.isNotEmpty) {
        bytes = await XFile(filePath).readAsBytes();
      }
      return _runPdfPipelineDirect(
        docId: docId,
        fileName: fileName,
        bytes: bytes,
        onProgress: onProgress,
        onBatch: onBatch,
      );
    }

    return _runPdfPipelineWithIsolate(
      docId: docId,
      fileName: fileName,
      filePath: hasPath ? filePath : null,
      fileBytes: hasBytes ? fileBytes : null,
      chunkWindowPages: chunkWindowPages,
      startFromPage: startFromPage,
      initialSequence: initialSequence,
      initialOffset: initialOffset,
      initialCarryOver: initialCarryOver,
      savedProfileJson: savedProfileJson,
      watchdogTimeout: watchdogTimeout,
      onProgress: onProgress,
      onBatch: onBatch,
    );
  }

  // --- PDF Long-Lived Isolate Execution (F23 & F33) ---

  static Future<IngestionResult> _runPdfPipelineWithIsolate({
    required String docId,
    required String fileName,
    String? filePath,
    List<int>? fileBytes,
    int chunkWindowPages = 16,
    int startFromPage = 1,
    int initialSequence = 1,
    int initialOffset = 0,
    String? initialCarryOver,
    String? savedProfileJson,
    Duration watchdogTimeout = const Duration(seconds: 90),
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch, {
      int? lastSequence,
      int? lastCharOffset,
      String? carryOverText,
      String? profileJson,
    })? onBatch,
  }) async {
    final completer = Completer<IngestionResult>();
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    // MEM-03: Incremental streaming hashes and stats (Zero whole-book string in UI isolate)
    final canonicalSink = AccumulatorSink<Digest>();
    final canonicalByteSink = sha256.startChunkedConversion(canonicalSink);
    final reconstructedSink = AccumulatorSink<Digest>();
    final reconstructedByteSink = sha256.startChunkedConversion(reconstructedSink);

    final initialChunksSample = <Map<String, Object?>>[];
    StringBuffer? inMemoryCanonicalBuffer;
    int totalWords = 0;
    int totalCharacters = 0;
    int totalChunkCount = 0;
    int totalPages = 0;
    Isolate? isolate;
    Timer? livenessTimer;
    const livenessDuration = Duration(seconds: 60);

    void cleanup() {
      livenessTimer?.cancel();
      livenessTimer = null;
      receivePort.close();
      errorPort.close();
      exitPort.close();
      try {
        isolate?.kill(priority: Isolate.immediate);
      } catch (e) {
        debugPrint('[Athena Ingestion] Isolate cleanup notice: $e');
      }
    }

    void resetLiveness() {
      livenessTimer?.cancel();
      livenessTimer = Timer(livenessDuration, () async {
        debugPrint('[Athena Ingestion] Liveness watchdog triggered: 60s without events');
        if (!completer.isCompleted) {
          completer.completeError(
            const AppError(
              code: 'EXTRACTION_TIMEOUT',
              message: 'Extraction timed out due to worker inactivity.',
            ),
          );
        }
        cleanup();
        try {
          await LocalDatabase.instance.updateDocumentProgress(
            docId,
            status: 'failed',
            stage: 'failed',
            stageLabel: 'Extraction timed out due to worker inactivity.',
            errorMessage: 'Extraction timed out due to worker inactivity.',
            errorCode: 'EXTRACTION_TIMEOUT',
          );
        } catch (e) {
          debugPrint('[Athena Ingestion] DB watchdog update notice: $e');
        }
      });
    }

    errorPort.listen((dynamic errorData) {
      if (!completer.isCompleted) {
        completer.completeError(
          AppError(
            code: 'EXTRACTION_FAILED',
            message: 'Extraction interrupted or out of memory: $errorData',
          ),
        );
      }
      cleanup();
    });

    exitPort.listen((dynamic _) {
      Future.delayed(const Duration(milliseconds: 50), () {
        if (!completer.isCompleted) {
          completer.completeError(
            const AppError(
              code: 'EXTRACTION_FAILED',
              message: 'Worker isolate exited unexpectedly',
            ),
          );
        }
        cleanup();
      });
    });

    try {
      isolate = await Isolate.spawn(
        _pdfWorkerIsolateEntryPoint,
        _PdfWorkerParams(
          docId: docId,
          fileName: fileName,
          filePath: filePath,
          bytes: fileBytes,
          sendPort: receivePort.sendPort,
          chunkWindowPages: chunkWindowPages,
          startFromPage: startFromPage,
          initialSequence: initialSequence,
          initialOffset: initialOffset,
          initialCarryOver: initialCarryOver,
          savedProfileJson: savedProfileJson,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );

      resetLiveness();

      receivePort.listen(
        (dynamic message) async {
          resetLiveness();
          if (message is _WorkerHeartbeatEvent) {
            // Worker is alive
          } else if (message is _WorkerProgressEvent) {
            onProgress?.call(message.progress, message.stageLabel);
          } else if (message is _WorkerBatchEvent) {
            totalPages = message.totalPages;
            totalChunkCount += message.batchChunks.length;
            if (initialChunksSample.length < 16) {
              initialChunksSample.addAll(
                message.batchChunks.take(16 - initialChunksSample.length),
              );
            }

            if (message.batchCanonicalText.isNotEmpty) {
              canonicalByteSink.add(utf8.encode(message.batchCanonicalText));
              totalCharacters += message.batchCanonicalText.length;
              totalWords += StructureResolver._countWordsStatic(message.batchCanonicalText);
              // For short documents or tests without onBatch persistence, retain canonicalText in memory (<= 2MB)
              if (onBatch == null || totalPages <= 10) {
                inMemoryCanonicalBuffer ??= StringBuffer();
                inMemoryCanonicalBuffer!.write(message.batchCanonicalText);
              }
            }

            for (final c in message.batchChunks) {
              final raw = c['raw_text']?.toString() ?? '';
              reconstructedByteSink.add(utf8.encode(raw));
            }

            if (onBatch != null) {
              livenessTimer?.cancel();
              try {
                await onBatch(
                  message.batchChunks,
                  message.processedPages,
                  message.totalPages,
                  message.isFinalBatch,
                  lastSequence: message.lastSequence,
                  lastCharOffset: message.lastCharOffset,
                  carryOverText: message.carryOverText,
                  profileJson: message.profileJson,
                );
              } finally {
                resetLiveness();
              }
            }
          } else if (message is _WorkerDoneEvent) {
            canonicalByteSink.close();
            reconstructedByteSink.close();

            final canonicalSha256 =
                canonicalSink.events.firstOrNull?.toString() ?? '';
            final reconstructedSha256 =
                reconstructedSink.events.firstOrNull?.toString() ?? '';

            if (totalChunkCount == 0) {
              if (!completer.isCompleted) {
                completer.completeError(
                  const AppError(
                    code: 'EMPTY_DOCUMENT',
                    message: 'No readable prose found in document.',
                  ),
                );
              }
              cleanup();
              return;
            }

            final bool integrityVerified = (canonicalSha256 == reconstructedSha256);

            if (message.chapters.isNotEmpty) {
              unawaited(LocalDatabase.instance.insertDocumentChapters(docId, message.chapters));
            }

            final result = IngestionResult(
              canonicalText: inMemoryCanonicalBuffer?.toString() ?? '',
              canonicalSha256: canonicalSha256,
              pageCount: message.pageCount > 0 ? message.pageCount : totalPages,
              chunks: initialChunksSample,
              integrityVerified: integrityVerified,
              totalWords: totalWords,
              totalCharacters: totalCharacters,
              chunkCount: totalChunkCount,
              chapters: message.chapters,
            );

            if (!completer.isCompleted) {
              completer.complete(result);
            }
            cleanup();
          } else if (message is _WorkerErrorEvent) {
            final err = AppError(
              code: message.errorCode ?? 'EXTRACTION_FAILED',
              message: message.error,
            );
            if (!completer.isCompleted) {
              completer.completeError(err);
            }
            cleanup();
            try {
              await LocalDatabase.instance.updateDocumentProgress(
                docId,
                status: 'failed',
                stage: 'failed',
                stageLabel: message.error,
                errorMessage: message.error,
                errorCode: message.errorCode ?? 'EXTRACTION_FAILED',
              );
            } catch (e) {
              debugPrint('[Athena Ingestion] DB worker error update notice: $e');
            }
          }
        },
        onError: (dynamic e) {
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(
              AppError(code: 'EXTRACTION_FAILED', message: e.toString()),
            );
          }
        },
        onDone: () {
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(
              const AppError(
                code: 'EXTRACTION_FAILED',
                message: 'Worker isolate terminated without completing.',
              ),
            );
          }
        },
      );

      return await completer.future;
    } catch (e) {
      cleanup();
      if (e is AppError) rethrow;
      throw AppError.fromException(e);
    }
  }

  static Future<IngestionResult> _runPdfPipelineDirect({
    required String docId,
    required String fileName,
    required List<int> bytes,
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch,
    )? onBatch,
  }) async {
    PdfDocument? pdfDoc;
    try {
      try {
        pdfDoc = PdfDocument(inputBytes: bytes);
      } catch (pdfOpenErr) {
        debugPrint(
            '[Athena Ingestion] Direct PdfDocument open failed ($pdfOpenErr)');
        throw const AppError(
          code: 'PDF_UNREADABLE',
          message: 'This PDF is encrypted or unreadable.',
        );
      }
      final int totalPages = pdfDoc.pages.count;
      var extractor = PdfTextExtractor(pdfDoc);
      final bookmarks = _extractPdfBookmarks(pdfDoc);

      final pageLinesMap = <int, List<LineFragment>>{};
      final pageRawTextMap = <int, String>{};

      int cleanPageCount = 0;
      const int windowSize = 25;
      for (int startPage = 0; startPage < totalPages; startPage += windowSize) {
        final endPage = (startPage + windowSize - 1).clamp(0, totalPages - 1);
        final progressFraction = 0.05 + 0.55 * ((endPage + 1) / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        final stageMsg =
            'Extracting pages ${startPage + 1}–${endPage + 1} of $totalPages ($pctInt%)...';
        onProgress?.call(progressFraction, stageMsg);

        for (int p = startPage; p <= endPage; p++) {
          final pageHeight = pdfDoc.pages[p].size.height;
          final lines = _extractHorizontalGroupedLines(extractor, p, pageHeight: pageHeight);
          pageLinesMap[p + 1] = lines;
          final rawText = lines.map((l) => l.text).join('\n');
          pageRawTextMap[p + 1] = rawText;
          if (rawText.trim().length >= 20 &&
              computePageQuality(rawText).isAcceptable) {
            cleanPageCount++;
          }
        }
      }

      if (totalPages >= 3 && (cleanPageCount / totalPages) < 0.15) {
        throw const AppError(
          code: 'SCANNED_PDF_DETECTED',
          message: 'Scanned image-only PDF detected (no extractable text layer).',
        );
      }

      onProgress?.call(0.65, 'Analyzing document layout and structure...');
      final processedResult = _processWholeDocument(
        docId: docId,
        totalPages: totalPages,
        pageLinesMap: pageLinesMap,
        pageRawTextMap: pageRawTextMap,
        bookmarks: bookmarks,
      );

      if (onBatch != null && processedResult.chunks.isNotEmpty) {
        await onBatch(
          processedResult.chunks,
          totalPages,
          totalPages,
          true,
        );
      }

      onProgress?.call(1.0, 'Ready to read');
      return processedResult;
    } finally {
      try {
        pdfDoc?.dispose();
      } catch (e) {
        debugPrint('[Athena Ingestion] pdfDoc dispose error: $e');
      }
    }
  }

  static PdfDocument _openPdfDoc(_PdfWorkerParams params) {
    List<int>? bytes = params.bytes;
    if ((bytes == null || bytes.isEmpty) &&
        params.filePath != null &&
        params.filePath!.isNotEmpty &&
        !kIsWeb) {
      final file = File(params.filePath!);
      if (file.existsSync()) {
        bytes = file.readAsBytesSync();
      }
    }
    if (bytes == null || bytes.isEmpty) {
      throw const AppError(
        code: 'PDF_UNREADABLE',
        message: 'No file bytes available for PDF extraction.',
      );
    }

    return PdfDocument(inputBytes: bytes);
  }

  // --- Worker Isolate (Windowed PDF Processing & Incremental Batch Emission) ---

  static void _pdfWorkerIsolateEntryPoint(_PdfWorkerParams params) {
    PdfDocument? pdfDoc;
    try {
      try {
        pdfDoc = _openPdfDoc(params);
      } catch (pdfOpenErr) {
        debugPrint(
            '[Athena Ingestion] Worker PdfDocument open failed ($pdfOpenErr)');
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'This PDF is encrypted or unreadable.',
        ));
        return;
      }
      final int totalPages = pdfDoc.pages.count;
      final extractor = PdfTextExtractor(pdfDoc);
      final bookmarks = _extractPdfBookmarks(pdfDoc);

      LayoutProfile profile;
      Set<String> repeatedHeadersFooters;
      String profileJson;

      if (params.savedProfileJson != null && params.savedProfileJson!.isNotEmpty) {
        try {
          final decoded = jsonDecode(params.savedProfileJson!) as Map<String, dynamic>;
          profile = LayoutProfile.fromJson(decoded['layout'] as Map<String, dynamic>);
          repeatedHeadersFooters = (decoded['furniture'] as List).map((e) => e.toString()).toSet();
          profileJson = params.savedProfileJson!;
        } catch (_) {
          profile = const LayoutProfile(
            bodyFontSize: 12.0,
            linePitch: 14.0,
            bodyLeft: 54.0,
            bodyRight: 550.0,
            indent: 0.0,
            usesIndent: false,
          );
          repeatedHeadersFooters = <String>{};
          profileJson = jsonEncode({
            'layout': profile.toJson(),
            'furniture': repeatedHeadersFooters.toList(),
          });
        }
      } else {
        // Pass 0: Fast 24-Page Sampled Profile (< 1s)
        final samplePages = <int>{};
        for (int p = 1; p <= 10 && p <= totalPages; p++) {
          samplePages.add(p);
        }
        for (int p = totalPages - 3; p <= totalPages; p++) {
          if (p >= 1) samplePages.add(p);
        }
        if (totalPages > 14) {
          final startBody = (totalPages * 0.15).round().clamp(1, totalPages);
          final endBody = (totalPages * 0.85).round().clamp(1, totalPages);
          if (endBody > startBody) {
            final step = (endBody - startBody) / 10.0;
            for (int i = 0; i < 10; i++) {
              samplePages.add((startBody + (i * step)).round().clamp(1, totalPages));
            }
          }
        }
        final sampleSorted = samplePages.toList()..sort();

        final sampleLinesMap = <int, List<LineFragment>>{};
        int cleanSampleCount = 0;
        int totalSampleChars = 0;

        for (final p in sampleSorted) {
          final pageHeight = pdfDoc.pages[p - 1].size.height;
          final lines = _extractHorizontalGroupedLines(extractor, p - 1, pageHeight: pageHeight);
          sampleLinesMap[p] = lines;
          final rawText = lines.map((l) => l.text).join('\n');
          totalSampleChars += rawText.trim().length;
          if (rawText.trim().length >= 20 && computePageQuality(rawText).isAcceptable) {
            cleanSampleCount++;
          }
        }

        // a) Scanned PDF detection (< 15% clean in sample)
        if (sampleSorted.isNotEmpty && (cleanSampleCount / sampleSorted.length) < 0.15) {
          if (totalSampleChars == 0) {
            params.sendPort.send(const _WorkerErrorEvent(
              error: 'No readable prose found in document.',
              errorCode: 'EMPTY_DOCUMENT',
            ));
          } else {
            params.sendPort.send(const _WorkerErrorEvent(
              error: 'No readable text could be extracted from this document. Scanned image-only files are not supported on-device.',
              errorCode: 'UNSUPPORTED_FORMAT',
            ));
          }
          return;
        }

        // b) Deterministic LayoutProfile & repeatedHeadersFooters furniture keys
        repeatedHeadersFooters = detectFurniture(sampleLinesMap);
        final cleanSampleLinesMap = <int, List<LineFragment>>{};
        for (final p in sampleSorted) {
          var lines = sampleLinesMap[p] ?? const [];
          lines = lines.where((line) {
            final ph = line.pageHeight > 0 ? line.pageHeight : 792.0;
            final inMargin = (line.top <= 0.08 * ph) || (line.bottom >= 0.92 * ph);
            if (!inMargin) return true;
            final key = _furnitureKey(line.text);
            final yBucket = (line.top / 4).round();
            if (repeatedHeadersFooters.contains('$key@$yBucket') ||
                repeatedHeadersFooters.contains('$key@${yBucket - 1}') ||
                repeatedHeadersFooters.contains('$key@${yBucket + 1}')) {
              return false;
            }
            if (_isLonePageNumber(line.text, pageIndex: p)) return false;
            return true;
          }).toList();
          cleanSampleLinesMap[p] = lines;
        }

        profile = LayoutProfile.compute(cleanSampleLinesMap);

        profileJson = jsonEncode({
          'layout': profile.toJson(),
          'furniture': repeatedHeadersFooters.toList(),
        });

        // Release sample lines from memory
        sampleLinesMap.clear();
        cleanSampleLinesMap.clear();
      }

      // Pass 1: True Bounded 16-Page Streaming Loop
      final int chunkWindowPages =
          params.chunkWindowPages > 0 ? params.chunkWindowPages : 16;
      final int startFromPage =
          params.startFromPage > 0 ? params.startFromPage : 1;
      int chunkSeq = params.initialSequence > 0 ? params.initialSequence : 1;
      int currentOffset = params.initialOffset >= 0 ? params.initialOffset : 0;
      String? currentCarryOver = params.initialCarryOver;
      int? prevReadablePage;
      String? activeSectionTitle;
      final allExtractedChapters = <Map<String, Object?>>[];

      for (int startP = startFromPage; startP <= totalPages; startP += chunkWindowPages) {
        final endP = (startP + chunkWindowPages - 1).clamp(startFromPage, totalPages);
        final isFinalWindow = (endP == totalPages);

        final progressFraction = 0.05 + 0.90 * (endP / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        params.sendPort.send(_WorkerProgressEvent(
          progress: progressFraction,
          stageLabel: 'Extracting pages $startP–$endP of $totalPages ($pctInt%)...',
        ));
        params.sendPort.send(const _WorkerHeartbeatEvent());

        // Extract ONLY pages startP..endP into memory
        final windowCleanLinesMap = <int, List<LineFragment>>{};
        final windowRawTextMap = <int, String>{};
        final explicitHeadingMap = <int, List<String>>{};
        final tocPages = <int>{};
        final tocTitles = <String>{};

        for (int p = startP; p <= endP; p++) {
          final pageHeight = pdfDoc.pages[p - 1].size.height;
          final lines = _extractHorizontalGroupedLines(extractor, p - 1, pageHeight: pageHeight);
          final rawText = lines.map((l) => l.text).join('\n');
          windowRawTextMap[p] = rawText;

          var cleanLines = lines.where((line) {
            final ph = line.pageHeight > 0 ? line.pageHeight : 792.0;
            final inMargin = (line.top <= 0.08 * ph) || (line.bottom >= 0.92 * ph);
            if (!inMargin) return true;
            final key = _furnitureKey(line.text);
            final yBucket = (line.top / 4).round();
            if (repeatedHeadersFooters.contains('$key@$yBucket') ||
                repeatedHeadersFooters.contains('$key@${yBucket - 1}') ||
                repeatedHeadersFooters.contains('$key@${yBucket + 1}')) {
              return false;
            }
            if (_isLonePageNumber(line.text, pageIndex: p)) return false;
            return true;
          }).toList();
          windowCleanLinesMap[p] = cleanLines;

          final tocRes = TocDetector.analyzePage(
            lines: cleanLines,
            bodyRight: profile.bodyRight,
            rawPageText: rawText,
            pageNum: p,
            totalPages: totalPages,
          );
          if (tocRes.isToc) {
            tocPages.add(p);
            for (final entry in tocRes.entries) {
              tocTitles.add(entry.title.toLowerCase());
              allExtractedChapters.add({
                'level': entry.level,
                'title': entry.title,
                'raw_page_label': entry.rawPageLabel,
                'is_roman': entry.isRoman ? 1 : 0,
                'start_page': entry.pageNumber,
                'start_chunk_index': null,
              });
            }
          }
          for (final l in cleanLines) {
            if (isStrictHeading(
              line: l,
              profile: profile,
              bookmarkTitle: bookmarks[p],
              tocTitles: tocTitles,
            )) {
              explicitHeadingMap.putIfAbsent(p, () => []).add(l.text.trim());
            }
          }
        }

        final roles = StructureResolver.smoothRolesForWindow(
          startPage: startP,
          endPage: endP,
          totalPages: totalPages,
          pageLinesMap: windowCleanLinesMap,
          pageRawTextMap: windowRawTextMap,
          bookmarks: bookmarks,
          tocPages: tocPages,
          explicitHeadingMap: explicitHeadingMap,
        );

        final windowBuffer = StringBuffer();
        final windowSpans = <Map<String, dynamic>>[];

        for (int p = startP; p <= endP; p++) {
          final roleIdx = p - startP;
          var role = (roleIdx >= 0 && roleIdx < roles.length)
              ? roles[roleIdx]
              : SectionRole.chapter;

          final bool isTocOrDirectory = tocPages.contains(p) ||
              SectionRole.fromString(activeSectionTitle ?? '') == SectionRole.toc ||
              RegExp(r'^(?:table\s+of\s+)?contents\b|^list\s+of\s+(?:bibliographic\s+)?abbreviations|^members\s+of\s+the\s+seminar', caseSensitive: false)
                  .hasMatch((activeSectionTitle ?? '').trim());

          if (isTocOrDirectory) {
            role = SectionRole.toc;
          }

          if (role.isMatter) {
            continue;
          }

          if (prevReadablePage != null && prevReadablePage != p - 1) {
            currentCarryOver = null;
          }
          prevReadablePage = p;

          var lines = windowCleanLinesMap[p] ?? const [];
          if (lines.isEmpty) continue;

          if (profile.hasTwoColumns && profile.columnGutterLeft > 0) {
            final col1 = lines
                .where((l) => l.right <= profile.columnGutterRight)
                .toList()
              ..sort((a, b) => a.top.compareTo(b.top));
            final col2 = lines
                .where((l) => l.left >= profile.columnGutterLeft)
                .toList()
              ..sort((a, b) => a.top.compareTo(b.top));
            final other = lines
                .where((l) =>
                    l.right > profile.columnGutterRight &&
                    l.left < profile.columnGutterLeft)
                .toList()
              ..sort((a, b) => a.top.compareTo(b.top));
            lines = [...col1, ...col2, ...other];
          }

          final pageHeading = (explicitHeadingMap[p]?.isNotEmpty ?? false)
              ? explicitHeadingMap[p]!.first
              : bookmarks[p] ??
                  (role != SectionRole.chapter ? role.displayLabel : null);

          final reflowResult = reflowLinesIntoParagraphs(
            lines: lines,
            pageNum: p,
            bookmarkTitle: pageHeading,
            carryOver: currentCarryOver,
            layoutProfile: profile,
          );

          currentCarryOver = reflowResult.carryOver;

          for (final para in reflowResult.paragraphs) {
            if (para.text.isEmpty) continue;
            if (windowBuffer.isNotEmpty) {
              windowBuffer.write('\n\n');
            }
            final start = windowBuffer.length;
            windowBuffer.write(para.text);
            final end = windowBuffer.length;

            final candidateTitle = para.sectionTitle ??
                pageHeading ??
                (role != SectionRole.chapter ? role.displayLabel : null);
            if (candidateTitle != null &&
                candidateTitle.trim().isNotEmpty &&
                candidateTitle.trim().toLowerCase() != 'chapter passage') {
              activeSectionTitle = candidateTitle.trim();
            }

            final effectiveTitle = activeSectionTitle ??
                (role != SectionRole.chapter ? role.displayLabel : 'Chapter 1');

            windowSpans.add({
              'start': start,
              'end': end,
              'page_start': p,
              'page_end': p,
              'type': para.isHeading ? 'heading' : 'paragraph',
              'section_title': effectiveTitle,
              'section_role': role.name,
            });
          }
        }

        // Flush carryover if final window
        if (isFinalWindow &&
            currentCarryOver != null &&
            currentCarryOver.isNotEmpty) {
          if (windowBuffer.isNotEmpty) windowBuffer.write('\n\n');
          final start = windowBuffer.length;
          windowBuffer.write(currentCarryOver);
          final end = windowBuffer.length;
          windowSpans.add({
            'start': start,
            'end': end,
            'page_start': totalPages,
            'page_end': totalPages,
            'type': 'paragraph',
            'section_title': activeSectionTitle,
            'section_role': 'chapter',
          });
          currentCarryOver = null;
        }

        var windowCanonical = windowBuffer.toString().trim();
        List<Map<String, Object?>> windowChunks = const [];

        if (windowCanonical.isNotEmpty) {
          final bool needsWindowSep = currentOffset > 0;
          if (needsWindowSep) {
            windowCanonical = '\n\n$windowCanonical';
            for (final span in windowSpans) {
              final s = span['start'] as int? ?? 0;
              final e = span['end'] as int? ?? 0;
              span['start'] = s + 2;
              span['end'] = e + 2;
            }
          }

          windowChunks = LosslessChunker().build(
            documentId: params.docId,
            canonicalText: windowCanonical,
            spans: windowSpans,
            initialSequence: chunkSeq,
            offsetDelta: currentOffset,
          );

          chunkSeq += windowChunks.length;
          currentOffset += utf8.encode(windowCanonical).length;
        }

        // CRITICAL: Clear processed pages from RAM immediately!
        windowCleanLinesMap.clear();
        windowRawTextMap.clear();
        explicitHeadingMap.clear();

        if (windowChunks.isNotEmpty || isFinalWindow) {
          params.sendPort.send(_WorkerBatchEvent(
            batchChunks: windowChunks,
            batchCanonicalText: windowCanonical,
            processedPages: endP,
            totalPages: totalPages,
            isFinalBatch: isFinalWindow,
            lastSequence: chunkSeq - 1,
            lastCharOffset: currentOffset,
            carryOverText: currentCarryOver,
            profileJson: profileJson,
          ));
        }
      }

      params.sendPort.send(_WorkerDoneEvent(
        canonicalText: '',
        canonicalSha256: '',
        pageCount: totalPages,
        chapters: allExtractedChapters,
      ));
    } catch (e, stack) {
      params.sendPort.send(_WorkerErrorEvent(
        error: '$e\n$stack',
      ));
    } finally {
      try {
        pdfDoc?.dispose();
      } catch (e) {
        debugPrint('[Athena Ingestion] pdfDoc dispose error: $e');
      }
    }
  }

  // --- PASS 2: Structure Resolver, LayoutProfile & TocDetector (FP-5 to FP-10) ---

  static bool continuesParagraph({
    required LineFragment a,
    required LineFragment b,
    required LayoutProfile profile,
    required bool isHeadingA,
  }) {
    final h = profile.bodyFontSize;
    final pitch = profile.linePitch;
    final pageLeft = (profile is PageLayoutProfile) ? profile.pageBodyLeft : profile.bodyLeft;
    final pageRight = (profile is PageLayoutProfile) ? profile.pageBodyRight : profile.bodyRight;
    final isRagged = (profile is PageLayoutProfile) && profile.isRaggedRight;

    // 1) 0.5 * h < (b.top - a.top) <= 1.8 * linePitch
    final verticalDiff = b.top - a.top;
    if (verticalDiff <= 0.5 * h || verticalDiff > 1.8 * pitch) {
      return false;
    }

    // 2) |a.fontSize - b.fontSize| <= 0.3 * h
    if ((a.fontSize - b.fontSize).abs() > 0.3 * h) {
      return false;
    }

    // 3) a and b overlap horizontally in the same column band
    final horizontalOverlap = min(a.right, b.right) - max(a.left, b.left);
    if (horizontalOverlap <= 0) {
      return false;
    }

    // 4) On justified pages: a.right >= 0.90 * bodyRight OR a ends with hyphen (or !endsWithSentenceTerminalPunctuation)
    // On ragged-right pages: rely on vertical gap (> 1.35 * linePitch) or indent rather than line width to end paragraphs (S-6, S-7)
    final aTrim = a.text.trim();
    final reachesRight = a.right >= 0.90 * pageRight;
    final endsHyphen = aTrim.endsWith('-') ||
        aTrim.endsWith('\u2010') ||
        aTrim.endsWith('\u2011');
    final endsTerminal = RegExp(r'[.!?…”"’]\s*$').hasMatch(aTrim);
    if (!isRagged) {
      if (!reachesRight && !endsHyphen && endsTerminal) {
        return false;
      }
    } else {
      if (verticalDiff > 1.35 * pitch && endsTerminal) {
        return false;
      }
    }

    // 5) b does not start with a bullet, numbered list marker, or opening dialogue quote when a ended a sentence
    final bTrim = b.text.trim();
    final bStartsList =
        RegExp(r'^(?:[•*\-–—▪▫◦]|\d+[.)]|\([a-zA-Z0-9]+\))\s+').hasMatch(bTrim);
    final bStartsQuote = RegExp(r'^["“‘\x27]').hasMatch(bTrim);
    if (endsTerminal && (bStartsList || bStartsQuote)) {
      return false;
    }

    // 6) b is NOT first-line indented ((b.left - pageLeft) >= 0.8 * h && <= 4.5 * h) (S-6, P2-01)
    if (profile.usesIndent) {
      final indentDiff = b.left - pageLeft;
      if (indentDiff >= 0.8 * h && indentDiff <= 4.5 * h) {
        return false;
      }
    }

    // 7) Neither a nor b has an internal tabular column gap >= 3 * h
    if (RegExp(r'\s{4,}').hasMatch(a.text) ||
        RegExp(r'\s{4,}').hasMatch(b.text)) {
      return false;
    }

    // 8) a is not a heading
    if (isHeadingA) {
      return false;
    }

    return true;
  }

  static bool isStrictHeading({
    required LineFragment line,
    required LayoutProfile profile,
    String? bookmarkTitle,
    Set<String>? tocTitles,
  }) {
    final text = line.text.trim();
    if (text.isEmpty) return false;
    final words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    // 1. (fontSize >= 1.15 * bodyFontSize AND words <= 14)
    if (line.fontSize >= 1.15 * profile.bodyFontSize && words.length <= 14) {
      return true;
    }

    final normText = _norm(text);

    // 2. Matches bookmark title
    if (bookmarkTitle != null && bookmarkTitle.isNotEmpty) {
      final normBm = _norm(bookmarkTitle);
      if (normText == normBm || normText.startsWith(normBm)) {
        return true;
      }
    }

    // 3. Matches TOC title
    if (tocTitles != null) {
      for (final t in tocTitles) {
        final normT = _norm(t);
        if (normText == normT || normText.startsWith(normT)) {
          return true;
        }
      }
    }

    // 4. Explicit section pattern
    final explicitSec = RegExp(
      r'^(?:chapter|part|book|section|preface|foreword|introduction|prologue|epilogue|afterword|appendix)\b',
      caseSensitive: false,
    );
    if (explicitSec.hasMatch(text) && words.length <= 14) {
      return true;
    }

    return false;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s\-_.,:;]+'), ' ').trim();

  static IngestionResult _processWholeDocument({
    required String docId,
    required int totalPages,
    required Map<int, List<LineFragment>> pageLinesMap,
    required Map<int, String> pageRawTextMap,
    required Map<int, String> bookmarks,
  }) {
    if (pageLinesMap.isEmpty) {
      return IngestionResult(
        canonicalText: '',
        canonicalSha256: sha256.convert(utf8.encode('')).toString(),
        pageCount: totalPages,
        chunks: const [],
        integrityVerified: true,
      );
    }

    // 1. Whole-book furniture removal (FP-6)
    final repeatedHeadersFooters = detectFurniture(pageLinesMap);
    final cleanLinesMap = <int, List<LineFragment>>{};
    for (int p = 1; p <= totalPages; p++) {
      var lines = pageLinesMap[p] ?? const [];
      lines = lines.where((line) {
        final ph = line.pageHeight > 0 ? line.pageHeight : 792.0;
        final inMargin = (line.top <= 0.08 * ph) || (line.bottom >= 0.92 * ph);
        if (!inMargin) return true; // NEVER strip lines outside top/bottom 8% margin!

        final key = _furnitureKey(line.text);
        final yBucket = (line.top / 4).round();
        if (repeatedHeadersFooters.contains('$key@$yBucket') ||
            repeatedHeadersFooters.contains('$key@${yBucket - 1}') ||
            repeatedHeadersFooters.contains('$key@${yBucket + 1}')) {
          return false;
        }
        if (_isLonePageNumber(line.text, pageIndex: p)) return false;
        return true;
      }).toList();
      cleanLinesMap[p] = lines;
    }

    // 2. Compute LayoutProfile (FP-6)
    final profile = LayoutProfile.compute(cleanLinesMap);

    // 3. TocDetector & Heading discovery (FP-8, FP-9)
    final tocPages = <int>{};
    final tocTitles = <String>{};
    final explicitHeadingMap = <int, String>{};
    final singleIsolateChapters = <Map<String, Object?>>[];

    for (int p = 1; p <= totalPages; p++) {
      final lines = cleanLinesMap[p] ?? const [];
      final rawText = pageRawTextMap[p] ?? '';
      final tocRes = TocDetector.analyzePage(
        lines: lines,
        bodyRight: profile.bodyRight,
        rawPageText: rawText,
        pageNum: p,
        totalPages: totalPages,
      );
      if (tocRes.isToc) {
        tocPages.add(p);
        for (final entry in tocRes.entries) {
          tocTitles.add(entry.title.toLowerCase());
          singleIsolateChapters.add({
            'level': entry.level,
            'title': entry.title,
            'raw_page_label': entry.rawPageLabel,
            'is_roman': entry.isRoman ? 1 : 0,
            'start_page': entry.pageNumber,
            'start_chunk_index': null,
          });
        }
      }
      for (final l in lines) {
        if (isStrictHeading(
          line: l,
          profile: profile,
          bookmarkTitle: bookmarks[p],
          tocTitles: tocTitles,
        )) {
          explicitHeadingMap[p] = l.text.trim();
          break;
        }
      }
    }

    // 4. StructureResolver: 5-state monotonic Viterbi smoothing (FP-9, FP-10)
    final roles = StructureResolver.smoothRoles(
      totalPages: totalPages,
      pageLinesMap: cleanLinesMap,
      pageRawTextMap: pageRawTextMap,
      bookmarks: bookmarks,
      tocPages: tocPages,
      explicitHeadingMap: explicitHeadingMap,
    );

    // 5. Paragraph reflow across the entire book
    final buffer = StringBuffer();
    final spans = <Map<String, dynamic>>[];
    String? currentCarryOver;
    int? prevReadablePage;
    String? activeSectionTitle;

    for (int p = 1; p <= totalPages; p++) {
      final roleIdx = p - 1;
      var role = (roleIdx < roles.length) ? roles[roleIdx] : SectionRole.chapter;

      final bool isTocOrDirectory = tocPages.contains(p) ||
          SectionRole.fromString(activeSectionTitle ?? '') == SectionRole.toc ||
          RegExp(r'^(?:table\s+of\s+)?contents\b|^list\s+of\s+(?:bibliographic\s+)?abbreviations|^members\s+of\s+the\s+seminar', caseSensitive: false)
              .hasMatch((activeSectionTitle ?? '').trim());

      if (isTocOrDirectory) {
        role = SectionRole.toc;
      }

      // Exclude non-reading matter (TOC, copyright, index, etc.)
      if (role.isMatter) {
        continue;
      }

      if (prevReadablePage != null && prevReadablePage != p - 1) {
        currentCarryOver = null;
      }
      prevReadablePage = p;

      var lines = cleanLinesMap[p] ?? const [];
      if (lines.isEmpty) continue;

      // 2-Column XY-cut ordering if applicable (FP-6)
      if (profile.hasTwoColumns && profile.columnGutterLeft > 0) {
        final col1 = lines
            .where((l) => l.right <= profile.columnGutterRight)
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
        final col2 = lines
            .where((l) => l.left >= profile.columnGutterLeft)
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
        final other = lines
            .where((l) =>
                l.right > profile.columnGutterRight &&
                l.left < profile.columnGutterLeft)
            .toList()
          ..sort((a, b) => a.top.compareTo(b.top));
        lines = [...col1, ...col2, ...other];
      }

      final pageHeading = explicitHeadingMap[p] ??
          bookmarks[p] ??
          (role != SectionRole.chapter ? role.displayLabel : null);

      final reflowResult = reflowLinesIntoParagraphs(
        lines: lines,
        pageNum: p,
        bookmarkTitle: pageHeading,
        carryOver: currentCarryOver,
        layoutProfile: profile,
      );

      currentCarryOver = reflowResult.carryOver;

      for (final para in reflowResult.paragraphs) {
        if (para.text.isEmpty) continue;
        if (buffer.isNotEmpty) {
          buffer.write('\n\n');
        }
        final start = buffer.length;
        buffer.write(para.text);
        final end = buffer.length;

        final candidateTitle = para.sectionTitle ??
            pageHeading ??
            (role != SectionRole.chapter ? role.displayLabel : null);
        if (candidateTitle != null &&
            candidateTitle.trim().isNotEmpty &&
            candidateTitle.trim().toLowerCase() != 'chapter passage') {
          activeSectionTitle = candidateTitle.trim();
        }

        final effectiveTitle = activeSectionTitle ??
            (role != SectionRole.chapter ? role.displayLabel : 'Chapter 1');

        spans.add({
          'start': start,
          'end': end,
          'page_start': p,
          'page_end': p,
          'type': para.isHeading ? 'heading' : 'paragraph',
          'section_title': effectiveTitle,
          'section_role': role.name,
        });
      }
    }

    // Flush any final carry over
    if (currentCarryOver != null && currentCarryOver.isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      final start = buffer.length;
      buffer.write(currentCarryOver);
      final end = buffer.length;
      spans.add({
        'start': start,
        'end': end,
        'page_start': totalPages,
        'page_end': totalPages,
        'type': 'paragraph',
        'section_title': activeSectionTitle ?? 'Chapter 1',
        'section_role': 'chapter',
      });
      currentCarryOver = null;
    }

    final canonicalStr = buffer.toString().trim();
    final canonicalSha256 =
        sha256.convert(utf8.encode(canonicalStr)).toString();

    // 6. Adaptive section chunking across the whole document (FP-5, FP-7)
    final chunks = LosslessChunker().build(
      documentId: docId,
      canonicalText: canonicalStr,
      spans: spans,
    );

    final reconstructedText =
        chunks.map((c) => (c['raw_text'] ?? '').toString()).join('');
    final reconstructedSha256 =
        sha256.convert(utf8.encode(reconstructedText)).toString();
    final bool integrityVerified = (canonicalSha256 == reconstructedSha256);

    if (singleIsolateChapters.isNotEmpty) {
      for (final ch in singleIsolateChapters) {
        final startPage = ch['start_page'] as int?;
        final title = (ch['title'] as String?)?.toLowerCase();
        if (startPage != null && startPage > 0) {
          final matchedIdx = chunks.indexWhere((c) {
            final pStart = (c['page_start'] as num?)?.toInt() ?? 0;
            final secTitle = (c['section_title'] as String?)?.toLowerCase();
            return pStart >= startPage || (title != null && secTitle != null && secTitle.contains(title));
          });
          if (matchedIdx >= 0) {
            ch['start_chunk_index'] = (chunks[matchedIdx]['sequence'] as num?)?.toInt() ?? matchedIdx;
          }
        }
      }
      try {
        unawaited(LocalDatabase.instance.insertDocumentChapters(docId, singleIsolateChapters));
      } catch (e) {
        debugPrint('[Athena] Error saving chapters: $e');
      }
    }

    return IngestionResult(
      canonicalText: canonicalStr,
      canonicalSha256: canonicalSha256,
      pageCount: totalPages,
      chunks: chunks,
      integrityVerified: integrityVerified,
      totalWords: StructureResolver._countWordsStatic(canonicalStr),
      totalCharacters: canonicalStr.length,
      chunkCount: chunks.length,
      chapters: singleIsolateChapters,
    );
  }



  // --- STAGE 1: Extract Lines with Visual Row Grouping (F03) ---

  static List<LineFragment> _extractHorizontalGroupedLines(
      PdfTextExtractor extractor, int pageIndex, {double pageHeight = 792.0}) {
    try {
      final List<TextLine> textLines =
          extractor.extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
      if (textLines.isEmpty) {
        // Fallback to raw text extraction
        final raw = extractor.extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);
        if (raw.trim().isEmpty) return const [];
        return raw.split('\n').where((s) => s.trim().isNotEmpty).map((s) {
          return LineFragment(
            text: s.trim(),
            top: 0,
            bottom: 12,
            left: 0,
            right: 400,
            height: 12,
            width: 400,
            pageHeight: pageHeight,
          );
        }).toList();
      }

      // Group fragments that share the same visual horizontal row (F03)
      // |curr.top - prev.top| <= prev.height * 0.55
      final rawFragments = <LineFragment>[];
      for (final line in textLines) {
        final b = line.bounds;
        final words = line.wordCollection;

        double calcFontSize = line.fontSize;
        if (calcFontSize <= 0 && words.isNotEmpty) {
          int totalWeight = 0;
          double weightedFont = 0.0;
          for (final w in words) {
            final weight = w.text.length;
            if (w.fontSize > 0 && weight > 0) {
              weightedFont += w.fontSize * weight;
              totalWeight += weight;
            }
          }
          if (totalWeight > 0) {
            calcFontSize = weightedFont / totalWeight;
          }
        }
        if (calcFontSize <= 0) calcFontSize = 12.0;

        String lineText;
        double rightCoord = b.left + b.width;
        if (words.isNotEmpty) {
          final buf = StringBuffer();
          for (int wIdx = 0; wIdx < words.length; wIdx++) {
            final w = words[wIdx];
            final wordSplit = safeSplitFusedWord(w.text);
            if (wIdx == 0) {
              buf.write(wordSplit);
            } else {
              final prevWord = words[wIdx - 1];
              final gap = w.bounds.left - (prevWord.bounds.left + prevWord.bounds.width);
              if (gap > calcFontSize * 1.8) {
                buf.write('    ');
              } else {
                buf.write(' ');
              }
              buf.write(wordSplit);
            }
          }
          lineText = buf.toString().trim();
          final lastW = words.last;
          final lastRight = lastW.bounds.left + lastW.bounds.width;
          if (lastRight > rightCoord) rightCoord = lastRight;
        } else {
          lineText = line.text.split(RegExp(r'\s+')).map(safeSplitFusedWord).join(' ').trim();
        }
        if (lineText.isEmpty) continue;

        final bool isBold = line.fontStyle.contains(PdfFontStyle.bold);

        rawFragments.add(LineFragment(
          text: lineText,
          top: b.top,
          bottom: b.bottom,
          left: b.left,
          right: rightCoord,
          height: b.height > 0 ? b.height : 12.0,
          width: b.width,
          fontSize: calcFontSize,
          pageHeight: pageHeight,
          isBold: isBold,
        ));
      }

      if (rawFragments.isEmpty) return const [];

      // Sort top-down, left-to-right
      rawFragments.sort((a, b) {
        final topDiff = a.top.compareTo(b.top);
        return topDiff != 0 ? topDiff : a.left.compareTo(b.left);
      });

      final groupedLines = <LineFragment>[];
      List<LineFragment> currentRow = [rawFragments.first];

      for (int i = 1; i < rawFragments.length; i++) {
        final curr = rawFragments[i];
        final prev = currentRow.last;

        if ((curr.top - prev.top).abs() <= prev.height * 0.55) {
          currentRow.add(curr);
        } else {
          // Flush previous row sorted left-to-right
          currentRow.sort((a, b) => a.left.compareTo(b.left));
          int totalWeight = 0;
          double weightedFont = 0.0;
          for (final f in currentRow) {
            final weight = f.text.length;
            weightedFont += f.fontSize * weight;
            totalWeight += weight;
          }
          final double rowFont = totalWeight > 0 ? (weightedFont / totalWeight) : currentRow.first.fontSize;
          final bool rowBold = currentRow.any((f) => f.isBold);
          final combinedText = _joinRowFragments(currentRow, calcFontSize: rowFont);
          final minTop = currentRow.map((f) => f.top).reduce(min);
          final maxBottom = currentRow.map((f) => f.bottom).reduce(max);
          final minLeft = currentRow.map((f) => f.left).reduce(min);
          final maxRight = currentRow.map((f) => f.right).reduce(max);

          groupedLines.add(LineFragment(
            text: combinedText.trim(),
            top: minTop,
            bottom: maxBottom,
            left: minLeft,
            right: maxRight,
            height: maxBottom - minTop,
            width: maxRight - minLeft,
            fontSize: rowFont,
            pageHeight: pageHeight,
            isBold: rowBold,
          ));

          currentRow = [curr];
        }
      }

      if (currentRow.isNotEmpty) {
        currentRow.sort((a, b) => a.left.compareTo(b.left));
        int totalWeight = 0;
        double weightedFont = 0.0;
        for (final f in currentRow) {
          final weight = f.text.length;
          weightedFont += f.fontSize * weight;
          totalWeight += weight;
        }
        final double rowFont = totalWeight > 0 ? (weightedFont / totalWeight) : currentRow.first.fontSize;
        final bool rowBold = currentRow.any((f) => f.isBold);
        final combinedText = _joinRowFragments(currentRow, calcFontSize: rowFont);
        final minTop = currentRow.map((f) => f.top).reduce(min);
        final maxBottom = currentRow.map((f) => f.bottom).reduce(max);
        final minLeft = currentRow.map((f) => f.left).reduce(min);
        final maxRight = currentRow.map((f) => f.right).reduce(max);

        groupedLines.add(LineFragment(
          text: combinedText.trim(),
          top: minTop,
          bottom: maxBottom,
          left: minLeft,
          right: maxRight,
          height: maxBottom - minTop,
          width: maxRight - minLeft,
          fontSize: rowFont,
          pageHeight: pageHeight,
          isBold: rowBold,
        ));
      }

      return groupedLines;
    } catch (_) {
      return const [];
    }
  }

  static String _joinRowFragments(List<LineFragment> fragments, {double calcFontSize = 12.0}) {
    if (fragments.isEmpty) return '';
    final buf = StringBuffer(fragments.first.text.trim());
    for (int i = 1; i < fragments.length; i++) {
      final prev = fragments[i - 1];
      final curr = fragments[i];
      final prevText = prev.text.trim();
      final currText = curr.text.trim();
      final gap = curr.left - prev.right;
      final effectiveFontSize = curr.fontSize > 0 ? curr.fontSize : calcFontSize;

      // Drop cap detection: single uppercase letter followed by lowercase token
      if (RegExp(r'^[A-Z]$').hasMatch(prevText) && RegExp(r'^[a-z]').hasMatch(currText)) {
        buf.write(currText);
      } else if (gap > effectiveFontSize * 1.8) {
        buf.write('    ');
        buf.write(currText);
      } else {
        buf.write(' ');
        buf.write(currText);
      }
    }
    return buf.toString();
  }

  // --- STAGE 2: Repeated Header / Footer & Page Number Detection (F04, FP-6) ---

  static Set<String> detectFurniture(Map<int, List<LineFragment>> pageLinesMap) =>
      _findRepeatedHeadersFooters(pageLinesMap);

  static Set<String> _findRepeatedHeadersFooters(
      Map<int, List<LineFragment>> pageLinesMap) {
    final occurrenceCount = <String, int>{};
    final totalPages = pageLinesMap.length;
    if (totalPages < 3) return const {};

    for (final lines in pageLinesMap.values) {
      if (lines.isEmpty) continue;
      final seenOnThisPage = <String>{};

      for (final l in lines) {
        final ph = l.pageHeight > 0 ? l.pageHeight : 792.0;
        final inMargin = (l.top <= 0.08 * ph) || (l.bottom >= 0.92 * ph);
        if (!inMargin) continue;

        final t = l.text.trim();
        if (t.length > 80 || t.endsWith('.') || t.endsWith('!') || t.endsWith('?')) {
          continue;
        }

        final baseKey = _furnitureKey(t);
        if (baseKey.length < 3) continue;

        // Bucket vertical Y to ±4pt
        final yBucket = (l.top / 4).round();
        final fullKey = '$baseKey@$yBucket';

        if (seenOnThisPage.add(fullKey)) {
          occurrenceCount[fullKey] = (occurrenceCount[fullKey] ?? 0) + 1;
        }
      }
    }

    final repeated = <String>{};
    for (final entry in occurrenceCount.entries) {
      final minPages = totalPages >= 4 ? 4 : 3;
      if (entry.value >= minPages && (entry.value / totalPages) >= 0.15) {
        repeated.add(entry.key);
      }
    }
    return repeated;
  }

  static String _furnitureKey(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'\d+'), '#')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isLonePageNumber(String text, {int pageIndex = 1}) {
    final t = text.trim();
    if (RegExp(r'^(?:page\s+)?\d{1,4}$', caseSensitive: false).hasMatch(t)) {
      return true;
    }
    if (pageIndex <= 35) {
      const frontRomans = {
        'i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x',
        'xi', 'xii', 'xiii', 'xiv', 'xv', 'xvi', 'xvii', 'xviii', 'xix', 'xx'
      };
      if (frontRomans.contains(t.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  // --- STAGE 3: Page Quality & OCR Corruption Gate (F02) ---

  static PageQualityScore computePageQuality(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return PageQualityScore(
        alphaRatio: 0.0,
        symbolNoiseRatio: 1.0,
        validWordRatio: 0.0,
        isAcceptable: false,
      );
    }

    final nonSpaceChars = trimmed.replaceAll(RegExp(r'\s+'), '');
    final unicodeLetters = RegExp(r'[\p{L}\p{M}\p{N}]', unicode: true).allMatches(trimmed).length;
    final alphaRatio =
        nonSpaceChars.isEmpty ? 0.0 : unicodeLetters / nonSpaceChars.length;

    // Detect if text is predominantly Latin ASCII vs multilingual/non-Latin scripts (LNG-01)
    final asciiLatinLetters = RegExp(r'[A-Za-z]').allMatches(trimmed).length;
    final isPredominantlyLatin =
        unicodeLetters > 0 && (asciiLatinLetters / unicodeLetters) > 0.90;

    // CJK detection where space-separated tokenization does not apply
    final cjkChars = RegExp(r'[\u3040-\u9FFF\uAC00-\uD7AF]').allMatches(trimmed).length;
    final isCjk = nonSpaceChars.isNotEmpty && (cjkChars / nonSpaceChars.length) >= 0.25;

    final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) {
      return PageQualityScore(
        alphaRatio: alphaRatio,
        symbolNoiseRatio: 0.0,
        validWordRatio: 0.0,
        isAcceptable: false,
      );
    }

    // OCR Corruption Symbols: \, |, ~, ^, {, }, :-, --, ll), 1\, () inside words
    final ocrNoiseRe = RegExp(
        r'''[\\|~^{}]|:-|--|ll\)|1\\|\(\)|[^\p{L}\p{M}\p{N}\s.,!?;:’'"“”()–—-]{2,}''',
        unicode: true);
    final vowelRe = RegExp(r'[aeiouyAEIOUY]');
    final cleanWordRe = RegExp(
        r"^[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*[.,!?;:»”’।॥؟)]?$",
        unicode: true);

    int noisyCount = 0;
    int validCount = 0;

    for (final token in tokens) {
      if (ocrNoiseRe.hasMatch(token)) {
        noisyCount++;
      }
      if (token.isNotEmpty && token.length <= 40) {
        if (cleanWordRe.hasMatch(token)) {
          if (!isPredominantlyLatin || vowelRe.hasMatch(token) || token.length == 1) {
            validCount++;
          }
        }
      }
    }

    final symbolNoiseRatio = noisyCount / tokens.length;
    double validWordRatio = validCount / tokens.length;

    // For CJK text where spaces are absent or sparse, evaluate quality by character purity
    if (isCjk) {
      validWordRatio = (1.0 - symbolNoiseRatio).clamp(0.0, 1.0);
    }

    final isAcceptable = (alphaRatio >= 0.60 &&
        symbolNoiseRatio <= 0.15 &&
        validWordRatio >= 0.45);

    return PageQualityScore(
      alphaRatio: alphaRatio,
      symbolNoiseRatio: symbolNoiseRatio,
      validWordRatio: validWordRatio,
      isAcceptable: isAcceptable,
    );
  }

  // --- STAGE 4: Scoring Front-Matter & Back-Matter Classifier (F01) ---

  static int scoreFrontOrBackMatter(List<LineFragment> lines, String pageText) {
    int score = 0;
    final lower = pageText.toLowerCase();
    final compact = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');

    // 1. Explicit blank page declaration
    if (compact.contains('intentionallyleftblank')) {
      score += 100;
    }

    // 2. Bollingen series & publisher markers
    if ((compact.contains('bolling') && compact.contains('series')) ||
        compact.contains('bollingenseries') ||
        compact.contains('bollingerseries')) {
      score += 40;
    }

    // 3. Imprint & publishing markers
    const markers = [
      'copyright',
      '©',
      'all rights reserved',
      'published by',
      'university press',
      'printed in',
      'bollingen series',
      'library of congress',
      'cataloging-in-publication',
      'isbn',
      'table of contents',
      'contents',
      'dedication',
      'all rights reserved. no part of this',
    ];

    for (final marker in markers) {
      if (lower.contains(marker) ||
          compact.contains(marker.replaceAll(RegExp(r'[^a-z0-9]'), ''))) {
        score += 25;
      }
    }

    // 4. Structural front-matter indicators: High uppercase/titlecase ratio + low punctuation
    int upperLines = 0;
    for (final l in lines) {
      final t = l.text.trim();
      if (t.isNotEmpty && t == t.toUpperCase() && t.length > 3) {
        upperLines++;
      }
    }
    final upperRatio = lines.isEmpty ? 0.0 : upperLines / lines.length;
    final sentencePunctCount = RegExp(r'[.!?]').allMatches(pageText).length;
    final wordCount = pageText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final avgWordsPerLine = lines.isEmpty ? 0.0 : wordCount / lines.length;

    if (upperRatio >= 0.45 && sentencePunctCount < 3 && avgWordsPerLine < 6.5) {
      score += 30;
    }

    // Substantive narrative prose protection (RC-04)
    // A preface, foreword, or prologue containing substantive prose (>= 50 words, >= 3 sentences)
    // must never be scored as blank front matter.
    if (sentencePunctCount >= 3 && wordCount >= 50) {
      final hasSubstantiveTitle = RegExp(r'\b(preface|foreword|introduction|prologue)\b', caseSensitive: false).hasMatch(lower);
      if (hasSubstantiveTitle && !compact.contains('intentionallyleftblank')) {
        score = 0;
      }
    }

    return score;
  }

  // --- STAGE 5 & 6: Reflow & Chapter Detection (F03, F04, F05, F06) ---

  static ReflowResult reflowLinesIntoParagraphs({
    required List<LineFragment> lines,
    required int pageNum,
    String? bookmarkTitle,
    String? carryOver,
    LayoutProfile? layoutProfile,
  }) {
    final paragraphs = <ParagraphInfo>[];
    if (lines.isEmpty) {
      return ReflowResult(paragraphs: const [], carryOver: carryOver);
    }

    final effectiveProfile = (layoutProfile is PageLayoutProfile)
        ? layoutProfile
        : PageLayoutProfile.compute(lines: lines, globalProfile: layoutProfile);

    // Determine average font size on page
    final avgFontSize = lines.map((l) => l.fontSize).reduce((a, b) => a + b) / lines.length;

    final currentPara = StringBuffer();
    bool pendingHyphenJoin = false;
    if (carryOver != null && carryOver.isNotEmpty) {
      final cTrim = carryOver.trim();
      final hyphenMatch = RegExp(r'([A-Za-z]+)[-\u2010\u2011]$').firstMatch(cTrim);
      if (hyphenMatch != null) {
        final prefix = hyphenMatch.group(1)!;
        if (!_isKnownCompoundPrefix(prefix.toLowerCase())) {
          // Strip hyphen and join directly with next line
          currentPara.write(cTrim.substring(0, hyphenMatch.start + prefix.length));
          pendingHyphenJoin = true;
        } else {
          // Preserve compound hyphen and join directly with next line
          currentPara.write(cTrim);
          pendingHyphenJoin = true;
        }
      } else {
        currentPara.write(cTrim);
        currentPara.write(' ');
      }
    }

    bool isCurrentHeading = false;
    String? currentSectionTitle = bookmarkTitle;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      var rawLine = line.text.trim();
      if (rawLine.isEmpty) continue;

      // Check for Heading / Chapter indicator (F06, S-4, S-5)
      final normLine = _norm(rawLine);
      final normBookmark = bookmarkTitle != null ? _norm(bookmarkTitle) : null;
      final isHeadingCandidate = (normBookmark != null && normBookmark.isNotEmpty &&
              (normLine == normBookmark || normLine.startsWith(normBookmark))) ||
          line.fontSize >= 1.30 * avgFontSize ||
          RegExp(r'^(?:Chapter|Section|Part|Book)\s+(?:\d+|[IVXLCDM]+|[A-Z][a-z]+)',
                  caseSensitive: false)
              .hasMatch(rawLine);

      if (isHeadingCandidate) {
        if (currentPara.isNotEmpty) {
          // Flush preceding paragraph
          paragraphs.add(ParagraphInfo(
            text: _cleanParagraph(currentPara.toString()),
            isHeading: isCurrentHeading,
            sectionTitle: currentSectionTitle,
          ));
          currentPara.clear();
        }
        // Emit heading as standalone paragraph (S-4, S-5)
        paragraphs.add(ParagraphInfo(
          text: _cleanParagraph(rawLine),
          isHeading: true,
          sectionTitle: rawLine,
        ));
        currentSectionTitle = rawLine;
        isCurrentHeading = false;
        continue;
      }

      // Check line-end hyphenation to join seamlessly with next line (FP-3)
      if ((rawLine.endsWith('-') || rawLine.endsWith('\u2010') || rawLine.endsWith('\u2011')) && i + 1 < lines.length) {
        final nextLine = lines[i + 1].text.trim();
        final match = RegExp(r'([A-Za-z]+)[-\u2010\u2011]$', caseSensitive: false).firstMatch(rawLine);
        final nextMatch = RegExp(r'^[A-Za-z]+', caseSensitive: false).firstMatch(nextLine);
        if (match != null && nextMatch != null) {
          final prefix = match.group(1)!;
          if (!_isKnownCompoundPrefix(prefix.toLowerCase())) {
            // Strip trailing hyphen so next line joins directly
            rawLine = rawLine.substring(0, match.start + prefix.length);
            if (currentPara.isNotEmpty && !currentPara.toString().endsWith(' ') && !currentPara.toString().endsWith('-')) {
              currentPara.write(' ');
            }
            currentPara.write(rawLine);
            pendingHyphenJoin = true;
            continue; // Continue without trailing space
          }
        }
      }

      // Check drop cap (FP-4)
      if (RegExp(r'^[A-Z]$').hasMatch(rawLine) && i + 1 < lines.length) {
        final nextLine = lines[i + 1].text.trim();
        if (RegExp(r'^[a-z]').hasMatch(nextLine)) {
          if (currentPara.isNotEmpty && !currentPara.toString().endsWith(' ')) {
            currentPara.write(' ');
          }
          currentPara.write(rawLine);
          pendingHyphenJoin = true;
          continue;
        }
      }

      if (!pendingHyphenJoin) {
        if (currentPara.isNotEmpty && !currentPara.toString().endsWith(' ') && !currentPara.toString().endsWith('-')) {
          currentPara.write(' ');
        }
      }
      pendingHyphenJoin = false;
      currentPara.write(rawLine);

      // Determine if a paragraph break occurs after this line
      bool isParagraphEnd = false;
      if (i + 1 < lines.length) {
        final nextLine = lines[i + 1];
        final continues = continuesParagraph(
          a: line,
          b: nextLine,
          profile: effectiveProfile,
          isHeadingA: isCurrentHeading,
        );
        if (!continues) {
          isParagraphEnd = true;
        }
      }

      if (isParagraphEnd) {
        paragraphs.add(ParagraphInfo(
          text: _cleanParagraph(currentPara.toString()),
          isHeading: isCurrentHeading,
          sectionTitle: currentSectionTitle,
        ));
        currentPara.clear();
        isCurrentHeading = false;
      }
    }

    String? trailingCarry;
    if (currentPara.isNotEmpty) {
      final text = currentPara.toString().trim();
      final endsWithSentenceClosing = RegExp(r'[.!?…”"’]\s*$').hasMatch(text);

      if (!endsWithSentenceClosing) {
        // Carry unfinished paragraph across page boundary (F05)
        trailingCarry = text;
      } else {
        paragraphs.add(ParagraphInfo(
          text: _cleanParagraph(text),
          isHeading: isCurrentHeading,
          sectionTitle: currentSectionTitle,
        ));
      }
    }

    return ReflowResult(
      paragraphs: paragraphs,
      carryOver: trailingCarry,
    );
  }

  /// Active line-end de-hyphenation (FP-3)
  /// Matches ASCII -, \u2010, \u2011 across lines, carryOver, and batch boundaries.
  static String healLineEndHyphen(String left, String right) {
    final lTrim = left.trimRight();
    final rTrim = right.trimLeft();
    if (lTrim.isEmpty) return rTrim;
    if (rTrim.isEmpty) return lTrim;

    final hyphenMatch = RegExp(r'([A-Za-z]+)[-\u2010\u2011]$').firstMatch(lTrim);
    final nextWordMatch = RegExp(r'^([A-Za-z]+)(.*)$', dotAll: true).firstMatch(rTrim);

    if (hyphenMatch != null && nextWordMatch != null) {
      final prefix = hyphenMatch.group(1)!;
      final suffixWord = nextWordMatch.group(1)!;
      final rest = nextWordMatch.group(2) ?? '';
      final beforeHyphen = lTrim.substring(0, hyphenMatch.start + prefix.length);

      if (_isKnownCompoundPrefix(prefix.toLowerCase())) {
        return '$beforeHyphen-$suffixWord$rest';
      } else {
        return '$beforeHyphen$suffixWord$rest';
      }
    }

    return '$lTrim $rTrim';
  }

  /// Fixes broken line-wrap hyphenation across line breaks (F04, Invariant 4).
  /// Preserves legitimate compound word prefixes ('self-esteem', 'anti-slop', 'co-author').
  static String dehyphenateLineWraps(String text) {
    if (!text.contains('-') && !text.contains('\u2010') && !text.contains('\u2011')) return text;
    return text.replaceAllMapped(RegExp(r'\b([A-Za-z]+)[-\u2010\u2011]\s+([a-z]+)\b'), (m) {
      final prefix = m.group(1)!;
      final suffix = m.group(2)!;
      if (_isKnownCompoundPrefix(prefix.toLowerCase())) {
        return '$prefix-$suffix';
      }
      return '$prefix$suffix';
    });
  }

  static bool _isKnownCompoundPrefix(String prefix) {
    const prefixes = {
      // Numerical compounds
      'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety',
      // Classical prefixes
      'self', 'non', 'anti', 'well', 'cross', 'quasi', 'pseudo', 'high', 'low', 'half', 'all', 'ex',
      // Common hyphenated compounds & relational terms
      'long', 'short', 'full', 'part', 'mother', 'father', 'brother', 'sister', 'daughter', 'son',
      'mid', 'co', 'pre', 'post', 'ultra', 'macro', 'micro', 'multi', 'inter', 'intra', 'extra',
      'ill',
    };
    return prefixes.contains(prefix);
  }

  static String _cleanParagraph(String text) {
    return sanitizeProseSpacing(text)
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  static Map<int, String> _extractPdfBookmarks(PdfDocument doc) {
    final bookmarks = <int, String>{};
    try {
      final bms = doc.bookmarks;
      for (int i = 0; i < bms.count; i++) {
        _walkBookmarks(doc, bms[i], bookmarks);
      }
    } catch (e) {
      debugPrint('[Athena Ingestion] extract bookmarks error: $e');
    }
    return bookmarks;
  }

  static void _walkBookmarks(
      PdfDocument doc, PdfBookmark bm, Map<int, String> bookmarks) {
    try {
      final dest = bm.destination;
      if (dest != null) {
        final pageIndex = doc.pages.indexOf(dest.page);
        if (pageIndex >= 0 && bm.title.trim().isNotEmpty) {
          bookmarks[pageIndex + 1] = bm.title.trim();
        }
      }
      for (int i = 0; i < bm.count; i++) {
        _walkBookmarks(doc, bm[i], bookmarks);
      }
    } catch (e) {
      debugPrint('[Athena Ingestion] child bookmark error: $e');
    }
  }

  // --- EPUB PIPELINE WITH COMPREHENSIVE HTML ENTITIES & CHAPTER NAVIGATION (F06, F34.6) ---

  static SectionRole _resolveEpubSectionRole({
    required String href,
    required String properties,
    String? htmlContent,
    String? sectionTitle,
  }) {
    final lowerHref = href.toLowerCase();
    final fileName = lowerHref.split('/').last;

    // 1. Check properties / epub:type in manifest or HTML
    final lowerProps = properties.toLowerCase();
    if (lowerProps.contains('nav') || lowerProps.contains('toc')) {
      return SectionRole.toc;
    }
    if (lowerProps.contains('cover')) {
      return SectionRole.cover;
    }

    // 2. Check HTML attributes epub:type / role="doc-*" ONLY on root <body ...> or top-level <section ...> (S-8)
    if (htmlContent != null && htmlContent.isNotEmpty) {
      final rootTagMatch = RegExp(
        r'<(?:body|section)\b[^>]*?(?:epub:type|role)\s*=\s*["''](?:doc-)?([^"'']+)["'']',
        caseSensitive: false,
      ).firstMatch(htmlContent);
      if (rootTagMatch != null) {
        final rawType = rootTagMatch.group(1)!.toLowerCase();
        final role = _roleFromTypeString(rawType);
        if (role != SectionRole.unknown) return role;
      }
    }

    // 3. Filename patterns
    if (RegExp(r'(?:^|[-_.])(?:toc|ncx|contents)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.toc;
    }
    if (RegExp(r'(?:^|[-_.])(?:cover)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.cover;
    }
    if (RegExp(r'(?:^|[-_.])(?:titlepage|title[-_]page)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.titlePage;
    }
    if (RegExp(r'(?:^|[-_.])(?:halftitle|half[-_]title)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.halfTitle;
    }
    if (RegExp(r'(?:^|[-_.])(?:copyright|colophon|imprint)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.copyright;
    }
    if (RegExp(r'(?:^|[-_.])(?:dedication)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.dedication;
    }
    if (RegExp(r'(?:^|[-_.])(?:epigraph)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.epigraph;
    }
    if (RegExp(r'(?:^|[-_.])(?:praise)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.praise;
    }
    if (RegExp(r'(?:^|[-_.])(?:alsoby|otherbooks)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.alsoBy;
    }
    if (RegExp(r'(?:^|[-_.])(?:loi|lot|figures|tables)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.listOfFigures;
    }
    if (RegExp(r'(?:^|[-_.])(?:preface)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.preface;
    }
    if (RegExp(r'(?:^|[-_.])(?:foreword)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.foreword;
    }
    if (RegExp(r'(?:^|[-_.])(?:intro|introduction)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.introduction;
    }
    if (RegExp(r'(?:^|[-_.])(?:prologue)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.prologue;
    }
    if (RegExp(r'(?:^|[-_.])(?:ack|acknowledg)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.acknowledgments;
    }
    if (RegExp(r'(?:^|[-_.])(?:notes|endnotes|rearnotes|footnotes)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.notes;
    }
    if (RegExp(r'(?:^|[-_.])(?:biblio|references)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.bibliography;
    }
    // Only classify as bookIndex if explicit index file AND title confirms index (S-8)
    if ((fileName == 'index.xhtml' || fileName == 'index.html') &&
        (sectionTitle != null && RegExp(r'\bindex\b', caseSensitive: false).hasMatch(sectionTitle))) {
      return SectionRole.bookIndex;
    }
    if (RegExp(r'(?:^|[-_.])(?:glossary)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.glossary;
    }
    if (RegExp(r'(?:^|[-_.])(?:about|biography|author)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.aboutAuthor;
    }
    if (RegExp(r'(?:^|[-_.])(?:adcard|advertisement)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.adCard;
    }
    if (RegExp(r'(?:^|[-_.])(?:epilogue)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.epilogue;
    }
    if (RegExp(r'(?:^|[-_.])(?:afterword)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.afterword;
    }
    if (RegExp(r'(?:^|[-_.])(?:appendix)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.appendix;
    }
    if (RegExp(r'(?:^|[-_.])(?:fm\d|frontmatter)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.titlePage;
    }
    if (RegExp(r'(?:^|[-_.])(?:bm\d|backmatter)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
      return SectionRole.notes;
    }

    // 4. Check section title if available
    if (sectionTitle != null && sectionTitle.isNotEmpty) {
      final roleFromTitle = SectionRole.fromString(sectionTitle);
      if (roleFromTitle != SectionRole.unknown) {
        return roleFromTitle;
      }
    }

    return SectionRole.chapter;
  }

  static SectionRole _roleFromTypeString(String type) {
    final t = type.toLowerCase();
    if (t.contains('toc')) return SectionRole.toc;
    if (t.contains('cover')) return SectionRole.cover;
    if (t.contains('titlepage')) return SectionRole.titlePage;
    if (t.contains('halftitle')) return SectionRole.halfTitle;
    if (t.contains('copyright') || t.contains('colophon')) return SectionRole.copyright;
    if (t.contains('dedication')) return SectionRole.dedication;
    if (t.contains('epigraph')) return SectionRole.epigraph;
    if (t.contains('praise')) return SectionRole.praise;
    if (t.contains('preface')) return SectionRole.preface;
    if (t.contains('foreword')) return SectionRole.foreword;
    if (t.contains('intro')) return SectionRole.introduction;
    if (t.contains('prologue')) return SectionRole.prologue;
    if (t.contains('ack')) return SectionRole.acknowledgments;
    if (t.contains('part')) return SectionRole.part;
    if (t.contains('chapter')) return SectionRole.chapter;
    if (t.contains('epilogue')) return SectionRole.epilogue;
    if (t.contains('afterword')) return SectionRole.afterword;
    if (t.contains('appendix')) return SectionRole.appendix;
    if (t.contains('note') || t.contains('endnote')) return SectionRole.notes;
    if (t.contains('biblio')) return SectionRole.bibliography;
    if (t.contains('index')) return SectionRole.bookIndex;
    if (t.contains('glossary')) return SectionRole.glossary;
    return SectionRole.unknown;
  }

  static Future<IngestionResult> _ingestEpubDirect({
    required String docId,
    required String fileName,
    required List<int> bytes,
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch,
    )? onBatch,
  }) async => _ingestEpub(
    docId: docId,
    fileName: fileName,
    bytes: bytes,
    onProgress: onProgress,
    onBatch: onBatch,
  );

  static Future<IngestionResult> _runEpubPipelineWithIsolate({
    required String docId,
    required String fileName,
    String? filePath,
    List<int>? fileBytes,
    int startFromPage = 1,
    int initialSequence = 1,
    int initialOffset = 0,
    String? initialCarryOver,
    Duration watchdogTimeout = const Duration(seconds: 90),
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch, {
      int? lastSequence,
      int? lastCharOffset,
      String? carryOverText,
      String? profileJson,
    })? onBatch,
  }) async {
    final completer = Completer<IngestionResult>();
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final allChunks = <Map<String, Object?>>[];
    final fullCanonical = StringBuffer();
    int totalSections = 0;
    Isolate? isolate;
    Timer? watchdogTimer;

    void cleanup() {
      watchdogTimer?.cancel();
      watchdogTimer = null;
      receivePort.close();
      errorPort.close();
      exitPort.close();
      try {
        isolate?.kill(priority: Isolate.immediate);
      } catch (e) {
        debugPrint('[Athena Ingestion] EPUB Isolate cleanup notice: $e');
      }
    }

    void resetWatchdog() {
      watchdogTimer?.cancel();
      watchdogTimer = Timer(watchdogTimeout, () async {
        debugPrint('[Athena Ingestion] EPUB Watchdog triggered: ${watchdogTimeout.inSeconds}s worker timeout');
        if (!completer.isCompleted) {
          completer.completeError(
            const AppError(
              code: 'EXTRACTION_TIMEOUT',
              message: 'EPUB extraction timed out or stalled.',
            ),
          );
        }
        cleanup();
        try {
          await LocalDatabase.instance.updateDocumentProgress(
            docId,
            status: 'failed',
            stage: 'failed',
            stageLabel: 'Extraction interrupted or timed out.',
            errorMessage: 'Extraction interrupted or timed out.',
            errorCode: 'EXTRACTION_TIMEOUT',
          );
        } catch (e) {
          debugPrint('[Athena Ingestion] DB watchdog update notice: $e');
        }
      });
    }

    errorPort.listen((dynamic error) {
      if (!completer.isCompleted) {
        completer.completeError(
          AppError(
            code: 'EXTRACTION_FAILED',
            message: 'Extraction interrupted or out of memory: $error',
          ),
        );
      }
      cleanup();
    });

    exitPort.listen((_) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AppError(
            code: 'EXTRACTION_INTERRUPTED',
            message: 'Worker isolate exited unexpectedly',
          ),
        );
      }
      cleanup();
    });

    try {
      isolate = await Isolate.spawn<_EpubWorkerParams>(
        _epubWorkerIsolateEntryPoint,
        _EpubWorkerParams(
          docId: docId,
          fileName: fileName,
          filePath: filePath,
          bytes: fileBytes,
          startFromPage: startFromPage,
          initialSequence: initialSequence,
          initialOffset: initialOffset,
          initialCarryOver: initialCarryOver,
          sendPort: receivePort.sendPort,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );

      resetWatchdog();

      receivePort.listen(
        (dynamic message) async {
          resetWatchdog();
          if (message is _WorkerProgressEvent) {
            onProgress?.call(message.progress, message.stageLabel);
          } else if (message is _WorkerBatchEvent) {
            totalSections = message.totalPages;
            allChunks.addAll(message.batchChunks);
            if (message.batchCanonicalText.isNotEmpty) {
              if (fullCanonical.isNotEmpty) fullCanonical.write('\n\n');
              fullCanonical.write(message.batchCanonicalText);
            }
            if (onBatch != null) {
              watchdogTimer?.cancel();
              try {
                await onBatch(
                  message.batchChunks,
                  message.processedPages,
                  message.totalPages,
                  message.isFinalBatch,
                  lastSequence: message.lastSequence,
                  lastCharOffset: message.lastCharOffset,
                  carryOverText: message.carryOverText,
                  profileJson: message.profileJson,
                );
              } finally {
                resetWatchdog();
              }
            }
          } else if (message is _WorkerDoneEvent) {
            cleanup();
            final canonicalStr = fullCanonical.isNotEmpty
                ? fullCanonical.toString()
                : message.canonicalText;
            final canonicalSha256 =
                sha256.convert(utf8.encode(canonicalStr)).toString();

            final reconstructedText = allChunks
                .map((c) => (c['raw_text'] ?? '').toString())
                .join('');
            final reconstructedSha256 =
                sha256.convert(utf8.encode(reconstructedText)).toString();
            final bool integrityVerified =
                reconstructedText == canonicalStr &&
                reconstructedSha256 == canonicalSha256;

            final result = IngestionResult(
              canonicalText: canonicalStr,
              canonicalSha256: message.canonicalSha256.isNotEmpty
                  ? message.canonicalSha256
                  : canonicalSha256,
              pageCount: message.pageCount > 0 ? message.pageCount : totalSections,
              chunks: allChunks,
              integrityVerified: integrityVerified,
            );

            if (!completer.isCompleted) {
              completer.complete(result);
            }
          } else if (message is _WorkerErrorEvent) {
            final err = AppError(
              code: message.errorCode ?? 'EXTRACTION_FAILED',
              message: message.error,
            );
            if (!completer.isCompleted) {
              completer.completeError(err);
            }
            cleanup();
            try {
              await LocalDatabase.instance.updateDocumentProgress(
                docId,
                status: 'failed',
                stage: 'failed',
                stageLabel: message.error,
                errorMessage: message.error,
                errorCode: message.errorCode ?? 'EXTRACTION_FAILED',
              );
            } catch (e) {
              debugPrint('[Athena Ingestion] DB worker error update notice: $e');
            }
          }
        },
        onError: (dynamic e) {
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(
              AppError(code: 'EXTRACTION_FAILED', message: e.toString()),
            );
          }
        },
        onDone: () {
          cleanup();
          if (!completer.isCompleted) {
            completer.completeError(
              const AppError(
                code: 'EXTRACTION_FAILED',
                message: 'Worker isolate terminated without completing.',
              ),
            );
          }
        },
      );

      return await completer.future;
    } catch (e) {
      cleanup();
      if (e is AppError) rethrow;
      throw AppError.fromException(e);
    }
  }

  static void _epubWorkerIsolateEntryPoint(_EpubWorkerParams params) async {
    try {
      List<int>? bytes = params.bytes;
      final bool hasFilePath = params.filePath != null &&
          params.filePath!.isNotEmpty &&
          !kIsWeb;

      if ((bytes == null || bytes.isEmpty) && !hasFilePath) {
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'EPUB file is unreadable or empty.',
        ));
        return;
      }

      params.sendPort.send(const _WorkerProgressEvent(
        progress: 0.1,
        stageLabel: 'Parsing EPUB spine and navigation manifests...',
      ));

      // MEM-05: Stream EPUB spine entries lazily without inflating embedded image binaries into RAM
      Archive archive;
      if (hasFilePath) {
        final inputStream = InputFileStream(params.filePath!);
        archive = ZipDecoder().decodeBuffer(inputStream);
      } else {
        archive = ZipDecoder().decodeBytes(bytes!);
      }
      final binaryExtensions = {
        '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg',
        '.ttf', '.otf', '.woff', '.woff2',
        '.mp3', '.m4a', '.mp4', '.wav', '.ogg'
      };
      final files = <String, ArchiveFile>{
        for (final file in archive.files)
          if (file.isFile &&
              !binaryExtensions.any((ext) => file.name.toLowerCase().endsWith(ext)))
            _normalizeEpubPath(file.name): file,
      };

      // DRM verification
      _checkEpubDrm(files);

      final containerBytes = files['META-INF/container.xml']?.content;
      if (containerBytes is! List<int>) {
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'Malformed EPUB: missing container.xml',
        ));
        return;
      }
      final container = XmlDocument.parse(decodeXmlBytes(containerBytes));
      final rootfile = container
          .findAllElements('rootfile')
          .firstOrNull
          ?.getAttribute('full-path');
      if (rootfile == null) {
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'Malformed EPUB: missing rootfile',
        ));
        return;
      }

      final opfPath = _normalizeEpubPath(rootfile);
      final opfBytes = files[opfPath]?.content;
      if (opfBytes is! List<int>) {
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'Malformed EPUB: missing OPF',
        ));
        return;
      }
      final package = XmlDocument.parse(decodeXmlBytes(opfBytes));

      final manifest = <String, ({String href, String properties})>{};
      for (final item in package.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id != null && href != null) {
          manifest[id] = (
            href: href,
            properties: item.getAttribute('properties') ?? '',
          );
        }
      }

      final spine = package.findAllElements('spine').firstOrNull;
      if (spine == null) {
        params.sendPort.send(const _WorkerErrorEvent(
          error: 'Malformed EPUB: missing spine',
        ));
        return;
      }

      final itemRefs = spine.findElements('itemref').toList();
      final totalSections = itemRefs.length;

      final buffer = StringBuffer();
      final spans = <Map<String, dynamic>>[];
      final startSpineIndex =
          params.startFromPage > 1 ? params.startFromPage - 1 : 0;
      int readableSectionCount = startSpineIndex;

      if (params.initialCarryOver != null &&
          params.initialCarryOver!.isNotEmpty) {
        buffer.write(params.initialCarryOver!);
      }

      for (int idx = startSpineIndex; idx < totalSections; idx++) {
        final itemRef = itemRefs[idx];
        if ((itemRef.getAttribute('linear') ?? '').toLowerCase() == 'no') continue;
        final idref = itemRef.getAttribute('idref');
        final item = idref == null ? null : manifest[idref];
        if (item == null) continue;

        final href = item.href;
        final resolvedPath = _resolveEpubHref(opfPath, href);
        final contentBytes = files[resolvedPath]?.content;
        if (contentBytes is! List<int>) continue;

        final htmlContent = decodeXmlBytes(contentBytes);
        final sectionTitle = _extractEpubHeading(htmlContent);
        final role = _resolveEpubSectionRole(
          href: href,
          properties: item.properties,
          htmlContent: htmlContent,
          sectionTitle: sectionTitle,
        );

        if (role.isMatter) {
          continue;
        }

        final text = _decodeEpubHtmlToProse(htmlContent);
        if (text.isEmpty) continue;

        readableSectionCount++;
        final progress = 0.1 + 0.6 * ((idx + 1) / totalSections);
        params.sendPort.send(_WorkerProgressEvent(
          progress: progress,
          stageLabel: 'Extracting section $readableSectionCount of $totalSections...',
        ));

        if (buffer.isNotEmpty) {
          buffer.write('\n\n');
        }

        final title = (sectionTitle != null && sectionTitle.isNotEmpty)
            ? sectionTitle
            : (role != SectionRole.chapter
                ? role.displayLabel
                : 'Chapter $readableSectionCount');

        if (sectionTitle != null &&
            sectionTitle.isNotEmpty &&
            text.startsWith(sectionTitle)) {
          final headingStart = buffer.length;
          buffer.write(sectionTitle);
          final headingEnd = buffer.length;

          spans.add({
            'start': headingStart,
            'end': headingEnd,
            'page_start': readableSectionCount,
            'page_end': readableSectionCount,
            'type': 'heading',
            'section_title': title,
            'section_role': role.name,
          });

          final remainingText = text.substring(sectionTitle.length).trim();
          if (remainingText.isNotEmpty) {
            buffer.write('\n\n');
            final bodyStart = buffer.length;
            buffer.write(remainingText);
            final bodyEnd = buffer.length;

            spans.add({
              'start': bodyStart,
              'end': bodyEnd,
              'page_start': readableSectionCount,
              'page_end': readableSectionCount,
              'type': 'paragraph',
              'section_title': title,
              'section_role': role.name,
            });
          }
        } else {
          final sectionStart = buffer.length;
          buffer.write(text);
          final sectionEnd = buffer.length;

          spans.add({
            'start': sectionStart,
            'end': sectionEnd,
            'page_start': readableSectionCount,
            'page_end': readableSectionCount,
            'type': 'paragraph',
            'section_title': title,
            'section_role': role.name,
          });
        }
      }

      final canonicalStr = buffer.toString();
      final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

      final allChunks = LosslessChunker().build(
        documentId: params.docId,
        canonicalText: canonicalStr,
        spans: spans,
        initialSequence: params.initialSequence,
        offsetDelta: params.initialOffset,
      );

      final lastSeq = allChunks.isNotEmpty
          ? (allChunks.last['sequence'] as num?)?.toInt() ??
              params.initialSequence
          : params.initialSequence;
      final lastOffset = params.initialOffset + canonicalStr.length;

      params.sendPort.send(_WorkerBatchEvent(
        batchChunks: allChunks,
        batchCanonicalText: canonicalStr,
        processedPages: readableSectionCount,
        totalPages: totalSections,
        isFinalBatch: true,
        lastSequence: lastSeq,
        lastCharOffset: lastOffset,
      ));

      params.sendPort.send(_WorkerDoneEvent(
        canonicalText: canonicalStr,
        canonicalSha256: canonicalSha256,
        pageCount: totalSections,
      ));
    } catch (e, stack) {
      params.sendPort.send(_WorkerErrorEvent(
        error: '$e\n$stack',
      ));
    }
  }

  static Future<IngestionResult> _ingestEpub({
    required String docId,
    required String fileName,
    required List<int> bytes,
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch,
    )? onBatch,
  }) async {
    onProgress?.call(0.1, 'Parsing EPUB spine and navigation manifests...');
    final archive = ZipDecoder().decodeBytes(bytes);
    final binaryExtensions = {
      '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg',
      '.ttf', '.otf', '.woff', '.woff2',
      '.mp3', '.m4a', '.mp4', '.wav', '.ogg'
    };
    final files = <String, ArchiveFile>{
      for (final file in archive.files)
        if (file.isFile &&
            !binaryExtensions.any((ext) => file.name.toLowerCase().endsWith(ext)))
          _normalizeEpubPath(file.name): file,
    };

    // DRM verification
    _checkEpubDrm(files);

    final containerBytes = files['META-INF/container.xml']?.content;
    if (containerBytes is! List<int>) {
      throw Exception('Malformed EPUB: missing container.xml');
    }
    final container = XmlDocument.parse(decodeXmlBytes(containerBytes));
    final rootfile = container
        .findAllElements('rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    if (rootfile == null) throw Exception('Malformed EPUB: missing rootfile');

    final opfPath = _normalizeEpubPath(rootfile);
    final opfBytes = files[opfPath]?.content;
    if (opfBytes is! List<int>) throw Exception('Malformed EPUB: missing OPF');
    final package = XmlDocument.parse(decodeXmlBytes(opfBytes));

    final manifest = <String, ({String href, String properties})>{};
    for (final item in package.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifest[id] = (
          href: href,
          properties: item.getAttribute('properties') ?? '',
        );
      }
    }

    final spine = package.findAllElements('spine').firstOrNull;
    if (spine == null) throw Exception('Malformed EPUB: missing spine');

    final itemRefs = spine.findElements('itemref').toList();
    final totalSections = itemRefs.length;

    final buffer = StringBuffer();
    final spans = <Map<String, dynamic>>[];
    int readableSectionCount = 0;

    for (int idx = 0; idx < totalSections; idx++) {
      final itemRef = itemRefs[idx];
      if ((itemRef.getAttribute('linear') ?? '').toLowerCase() == 'no') continue;
      final idref = itemRef.getAttribute('idref');
      final item = idref == null ? null : manifest[idref];
      if (item == null) continue;

      final href = item.href;
      final resolvedPath = _resolveEpubHref(opfPath, href);
      final contentBytes = files[resolvedPath]?.content;
      if (contentBytes is! List<int>) continue;

      final htmlContent = decodeXmlBytes(contentBytes);
      final sectionTitle = _extractEpubHeading(htmlContent);
      final role = _resolveEpubSectionRole(
        href: href,
        properties: item.properties,
        htmlContent: htmlContent,
        sectionTitle: sectionTitle,
      );

      // Exclude non-reading matter (TOC, copyright, cover, notes, bibliography, index, etc.)
      if (role.isMatter) {
        continue;
      }

      final text = _decodeEpubHtmlToProse(htmlContent);
      if (text.isEmpty) continue;

      readableSectionCount++;
      final progress = 0.1 + 0.6 * ((idx + 1) / totalSections);
      onProgress?.call(progress, 'Extracting section $readableSectionCount of $totalSections...');

      if (buffer.isNotEmpty) {
        buffer.write('\n\n');
      }

      final title = (sectionTitle != null && sectionTitle.isNotEmpty)
          ? sectionTitle
          : (role != SectionRole.chapter
              ? role.displayLabel
              : 'Chapter $readableSectionCount');

      if (sectionTitle != null &&
          sectionTitle.isNotEmpty &&
          text.startsWith(sectionTitle)) {
        final headingStart = buffer.length;
        buffer.write(sectionTitle);
        final headingEnd = buffer.length;

        spans.add({
          'start': headingStart,
          'end': headingEnd,
          'page_start': readableSectionCount,
          'page_end': readableSectionCount,
          'type': 'heading',
          'section_title': title,
          'section_role': role.name,
        });

        final remainingText = text.substring(sectionTitle.length).trim();
        if (remainingText.isNotEmpty) {
          buffer.write('\n\n');
          final bodyStart = buffer.length;
          buffer.write(remainingText);
          final bodyEnd = buffer.length;

          spans.add({
            'start': bodyStart,
            'end': bodyEnd,
            'page_start': readableSectionCount,
            'page_end': readableSectionCount,
            'type': 'paragraph',
            'section_title': title,
            'section_role': role.name,
          });
        }
      } else {
        final sectionStart = buffer.length;
        buffer.write(text);
        final sectionEnd = buffer.length;

        spans.add({
          'start': sectionStart,
          'end': sectionEnd,
          'page_start': readableSectionCount,
          'page_end': readableSectionCount,
          'type': 'paragraph',
          'section_title': title,
          'section_role': role.name,
        });
      }
    }

    final canonicalStr = buffer.toString();
    final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

    // Run LosslessChunker().build across the whole reconstructed book
    final allChunks = LosslessChunker().build(
      documentId: docId,
      canonicalText: canonicalStr,
      spans: spans,
    );

    if (onBatch != null && allChunks.isNotEmpty) {
      await onBatch(
        allChunks,
        readableSectionCount,
        readableSectionCount,
        true,
      );
    }

    final reconstructedText =
        allChunks.map((c) => (c['raw_text'] ?? '').toString()).join('');
    final reconstructedSha256 =
        sha256.convert(utf8.encode(reconstructedText)).toString();
    final bool integrityVerified = (canonicalSha256 == reconstructedSha256);

    return IngestionResult(
      canonicalText: canonicalStr,
      canonicalSha256: canonicalSha256,
      pageCount: totalSections,
      chunks: allChunks,
      integrityVerified: integrityVerified,
    );
  }

  /// Check if EPUB archive contains DRM encryption or rights management
  static void _checkEpubDrm(Map<String, ArchiveFile> files) {
    if (files.containsKey('META-INF/encryption.xml')) {
      final encBytes = files['META-INF/encryption.xml']?.content;
      if (encBytes is List<int>) {
        final encXml = utf8.decode(encBytes, allowMalformed: true);
        // Exclude pure font-obfuscation algorithms (IDPF / Adobe font mangling)
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
    if (files.containsKey('META-INF/rights.xml')) {
      throw const AppError(
        code: 'DRM_PROTECTED',
        message: 'This EPUB is DRM-protected and cannot be read.',
      );
    }
  }

  /// Decode XML or XHTML byte content with BOM and XML declaration encoding detection
  static String decodeXmlBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // Check BOM
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        // UTF-16 LE
        final uint16 = Uint16List.view(Uint8List.fromList(bytes.sublist(2)).buffer);
        return String.fromCharCodes(uint16);
      } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        // UTF-16 BE
        final swapped = Uint8List(bytes.length - 2);
        for (int i = 2; i < bytes.length; i += 2) {
          if (i + 1 < bytes.length) {
            swapped[i - 2] = bytes[i + 1];
            swapped[i - 1] = bytes[i];
          }
        }
        final uint16 = Uint16List.view(swapped.buffer);
        return String.fromCharCodes(uint16);
      }
    }

    // Try standard UTF-8 first
    try {
      final text = utf8.decode(bytes);
      return text;
    } catch (_) {
      // Check XML header for encoding="..."
      final headProbe = latin1.decode(bytes.sublist(0, min(bytes.length, 256)));
      final encMatch = RegExp(r'encoding=["\x27]([^"\x27]+)["\x27]', caseSensitive: false).firstMatch(headProbe);
      if (encMatch != null) {
        final enc = encMatch.group(1)!.toLowerCase();
        if (enc.contains('latin') || enc.contains('1252') || enc.contains('iso-8859')) {
          return latin1.decode(bytes);
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String? _extractEpubHeading(String html) {
    final hMatch = RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false)
        .firstMatch(html);
    if (hMatch != null) {
      final raw = hMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (raw.isNotEmpty) return decodeHtmlEntities(raw);
    }
    return null;
  }

  /// Clean, DOM/tag-aware HTML-to-prose decoder (EPUB inline-tag fidelity).
  static String decodeEpubHtmlToProse(String html) {
    if (html.isEmpty) return '';

    // 1. Strip script, style, head, svg, nav, and aside blocks
    var content = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<svg[^>]*>[\s\S]*?</svg>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<nav[^>]*>[\s\S]*?</nav>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<aside[^>]*>[\s\S]*?</aside>', caseSensitive: false), ' ');

    // 2. Strip footnote callouts: <sup>...</sup> when <= 4 chars or containing noteref
    content = content.replaceAllMapped(
      RegExp(r'<sup[^>]*>([\s\S]*?)</sup>', caseSensitive: false),
      (m) {
        final inner = m.group(1)!;
        if (inner.contains('noteref') || inner.replaceAll(RegExp(r'<[^>]+>'), '').trim().length <= 4) {
          return '';
        }
        return inner;
      },
    );

    final buf = StringBuffer();
    int lastChar1 = -1;
    int lastChar2 = -1;

    void writeStr(String s) {
      if (s.isEmpty) return;
      buf.write(s);
      if (s.length == 1) {
        lastChar1 = lastChar2;
        lastChar2 = s.codeUnitAt(0);
      } else {
        lastChar1 = s.codeUnitAt(s.length - 2);
        lastChar2 = s.codeUnitAt(s.length - 1);
      }
    }

    final tagOrTextRegex = RegExp(r'(<[^>]+>)|([^<]+)');
    const blockTags = {
      'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li',
      'blockquote', 'hr', 'tr', 'section', 'article',
      'header', 'footer', 'table', 'dl', 'dt', 'dd', 'pre'
    };

    for (final match in tagOrTextRegex.allMatches(content)) {
      final tag = match.group(1);
      final text = match.group(2);

      if (tag != null) {
        final nameMatch = RegExp(r'^</?([a-zA-Z0-9]+)').firstMatch(tag);
        if (nameMatch != null) {
          final tagName = nameMatch.group(1)!.toLowerCase();
          if (tagName == 'br') {
            writeStr('\n');
          } else if (blockTags.contains(tagName)) {
            if (lastChar2 != -1) {
              if (lastChar1 == 0x0A && lastChar2 == 0x0A) {
                // already double newline
              } else if (lastChar2 == 0x0A) {
                writeStr('\n');
              } else {
                writeStr('\n\n');
              }
            }
          }
          // Inline tags (span, em, i, a, b, strong, sub, sup, code, u, small, mark, font, q, cite, abbr, dfn, kbd, samp, var, time, bdi, bdo, wbr) emit NOTHING
        }
      } else if (text != null) {
        writeStr(decodeHtmlEntities(text));
      }
    }

    final decoded = buf.toString();
    return sanitizeProseSpacing(decoded);
  }

  static String decodeHtmlForTest(String html) => decodeEpubHtmlToProse(html);

  static void checkEpubDrmForTest(Map<String, ArchiveFile> files) =>
      _checkEpubDrm(files);

  static SectionRole resolveEpubSectionRoleForTest({
    required String href,
    required String properties,
    String? htmlContent,
    String? sectionTitle,
  }) =>
      _resolveEpubSectionRole(
        href: href,
        properties: properties,
        htmlContent: htmlContent,
        sectionTitle: sectionTitle,
      );

  static String _decodeEpubHtmlToProse(String html) => decodeEpubHtmlToProse(html);

  /// Full HTML entity decoder (F06, F34.6)
  /// Decodes named HTML entities (&eacute;, &uuml;, &mdash;, &shy;, etc.) and decimal/hex numeric entities.
  static String decodeHtmlEntities(String text) {
    const namedEntities = {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
      'shy': '', // soft hyphen -> deleted (FP-4)
      'zwj': '', // zero-width joiner
      'zwnj': '', // zero-width non-joiner
      'thinsp': ' ',
      'ensp': ' ',
      'emsp': ' ',
      'mdash': '—',
      'ndash': '–',
      'hellip': '…',
      'ldquo': '“',
      'rdquo': '”',
      'lsquo': '‘',
      'rsquo': '’',
      'eacute': 'é',
      'Eacute': 'É',
      'egrave': 'è',
      'Egrave': 'È',
      'ecirc': 'ê',
      'Ecirc': 'Ê',
      'euml': 'ë',
      'Euml': 'Ë',
      'agrave': 'à',
      'Agrave': 'À',
      'aacute': 'á',
      'Aacute': 'Á',
      'acirc': 'â',
      'Acirc': 'Â',
      'auml': 'ä',
      'Auml': 'Ä',
      'ccedil': 'ç',
      'Ccedil': 'Ç',
      'icirc': 'î',
      'Icirc': 'Î',
      'iuml': 'ï',
      'Iuml': 'Ï',
      'ocirc': 'ô',
      'Ocirc': 'Ô',
      'ouml': 'ö',
      'Ouml': 'Ö',
      'ugrave': 'ù',
      'Ugrave': 'Ù',
      'uacute': 'ú',
      'Uacute': 'Ú',
      'ucirc': 'û',
      'Ucirc': 'Û',
      'uuml': 'ü',
      'Uuml': 'Ü',
      'copy': '©',
      'reg': '®',
      'trade': '™',
      'bull': '•',
    };

    return text.replaceAllMapped(
      RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'),
      (match) {
        final entity = match[1]!;
        if (namedEntities.containsKey(entity)) {
          return namedEntities[entity]!;
        }
        final lower = entity.toLowerCase();
        if (namedEntities.containsKey(lower)) {
          return namedEntities[lower]!;
        }
        try {
          if (entity.startsWith('#x') || entity.startsWith('#X')) {
            final code = int.parse(entity.substring(2), radix: 16);
            if (code >= 0 && code <= 0x10ffff) return String.fromCharCode(code);
          } else if (entity.startsWith('#')) {
            final code = int.parse(entity.substring(1));
            if (code >= 0 && code <= 0x10ffff) return String.fromCharCode(code);
          }
        } catch (e) {
          debugPrint('[Athena Ingestion] numeric entity parse error: $e');
        }
        return match[0]!;
      },
    );
  }

  static String _normalizeEpubPath(String path) {
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

  static String _resolveEpubHref(String opfPath, String href) {
    final decoded = Uri.decodeComponent(href.split('#').first.split('?').first);
    final opfDirectory = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/'))
        : '';
    return _normalizeEpubPath(
        opfDirectory.isEmpty ? decoded : '$opfDirectory/$decoded');
  }
}

// --- Worker Isolate Communication Models ---

class _PdfWorkerParams {
  final String docId;
  final String fileName;
  final String? filePath;
  final List<int>? bytes;
  final SendPort sendPort;
  final int chunkWindowPages;
  final int startFromPage;
  final int initialSequence;
  final int initialOffset;
  final String? initialCarryOver;
  final String? savedProfileJson;

  const _PdfWorkerParams({
    required this.docId,
    required this.fileName,
    this.filePath,
    this.bytes,
    required this.sendPort,
    this.chunkWindowPages = 16,
    this.startFromPage = 1,
    this.initialSequence = 1,
    this.initialOffset = 0,
    this.initialCarryOver,
    this.savedProfileJson,
  });
}

class _EpubWorkerParams {
  final String docId;
  final String fileName;
  final String? filePath;
  final List<int>? bytes;
  final SendPort sendPort;
  final int startFromPage;
  final int initialSequence;
  final int initialOffset;
  final String? initialCarryOver;

  const _EpubWorkerParams({
    required this.docId,
    required this.fileName,
    this.filePath,
    this.bytes,
    required this.sendPort,
    this.startFromPage = 1,
    this.initialSequence = 1,
    this.initialOffset = 0,
    this.initialCarryOver,
  });
}

class _WorkerProgressEvent {
  final double progress;
  final String stageLabel;

  const _WorkerProgressEvent({
    required this.progress,
    required this.stageLabel,
  });
}

class _WorkerHeartbeatEvent {
  const _WorkerHeartbeatEvent();
}

class _WorkerBatchEvent {
  final List<Map<String, Object?>> batchChunks;
  final String batchCanonicalText;
  final int processedPages;
  final int totalPages;
  final bool isFinalBatch;
  final int lastSequence;
  final int lastCharOffset;
  final String? carryOverText;
  final String? profileJson;

  const _WorkerBatchEvent({
    required this.batchChunks,
    required this.batchCanonicalText,
    required this.processedPages,
    required this.totalPages,
    required this.isFinalBatch,
    this.lastSequence = 0,
    this.lastCharOffset = 0,
    this.carryOverText,
    this.profileJson,
  });
}

class _WorkerDoneEvent {
  final String canonicalText;
  final String canonicalSha256;
  final int pageCount;
  final List<Map<String, Object?>> chapters;

  const _WorkerDoneEvent({
    required this.canonicalText,
    required this.canonicalSha256,
    required this.pageCount,
    this.chapters = const [],
  });
}

class _WorkerErrorEvent {
  final String error;
  final String? errorCode;

  const _WorkerErrorEvent({required this.error, this.errorCode});
}



class ParagraphInfo {
  final String text;
  final bool isHeading;
  final String? sectionTitle;

  const ParagraphInfo({
    required this.text,
    this.isHeading = false,
    this.sectionTitle,
  });
}

class PageQualityScore {
  final double alphaRatio;
  final double symbolNoiseRatio;
  final double validWordRatio;
  final bool isAcceptable;

  const PageQualityScore({
    required this.alphaRatio,
    required this.symbolNoiseRatio,
    required this.validWordRatio,
    required this.isAcceptable,
  });
}

class ReflowResult {
  final List<ParagraphInfo> paragraphs;
  final String? carryOver;

  const ReflowResult({
    required this.paragraphs,
    this.carryOver,
  });
}

class TocEntry {
  final String title;
  final int pageNumber;
  final String rawPageLabel;
  final bool isRoman;
  final int level;

  const TocEntry({
    required this.title,
    required this.pageNumber,
    this.rawPageLabel = '',
    this.isRoman = false,
    this.level = 1,
  });
}

class TocPageMatch {
  final int pageNumber;
  final bool isRoman;
  final String rawLabel;

  const TocPageMatch({
    required this.pageNumber,
    required this.isRoman,
    required this.rawLabel,
  });
}

class TocDetectionResult {
  final bool isToc;
  final List<TocEntry> entries;
  const TocDetectionResult({required this.isToc, required this.entries});
}

class TocDetector {
  static final contentsHeaderRe =
      RegExp(r'^(?:table\s+of\s+)?contents\b', caseSensitive: false);

  static final Map<String, int> _romanMap = _buildRomanMap();

  static Map<String, int> _buildRomanMap() {
    final map = <String, int>{};
    const hundreds = ['', 'c', 'cc', 'ccc', 'cd', 'd'];
    const tens = ['', 'x', 'xx', 'xxx', 'xl', 'l', 'lx', 'lxx', 'lxxx', 'xc'];
    const ones = ['', 'i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix'];

    for (int num = 1; num <= 500; num++) {
      final h = (num % 1000) ~/ 100;
      final t = (num % 100) ~/ 10;
      final o = num % 10;
      final s = '${hundreds[h]}${tens[t]}${ones[o]}';
      if (s.isNotEmpty) {
        map[s] = num;
      }
    }
    return map;
  }

  static int? parseRoman(String s) => _romanMap[s.trim().toLowerCase()];

  static String cleanTocTitle(String rawTitle) {
    var t = rawTitle.trim();
    t = t.replaceAll(RegExp(r'[\.…\-_]+$'), '').trim();

    // Fix OCR date tokens like "r6May1934" -> "16 May 1934"
    t = t.replaceAllMapped(
      RegExp(r'\b([0-9lr]{1,2})([A-Z][a-z]{2,8})(\d{4})\b'),
      (m) {
        var d = m.group(1)!;
        d = d.replaceAll('l', '1').replaceAll('r', '1');
        final month = m.group(2)!;
        final year = m.group(3)!;
        return '$d $month $year';
      },
    );

    // Vintage scanner OCR glyph corruptions
    t = t.replaceAll(RegExp(r"['`]?r[il]O[!1|l\\]+", caseSensitive: false), 'tion');
    t = t.replaceAll(RegExp(r"['`]?t[il]O[!1|l\\]+", caseSensitive: false), 'tion');
    t = t.replaceAll(RegExp(r"I['`\\]+\s*S\b", caseSensitive: false), 'NS');
    t = t.replaceAll(RegExp(r"I['`\\]+", caseSensitive: false), 'N');
    t = t.replaceAll(RegExp(r"![\\/]+"), 'n');

    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    final prefixMatch =
        RegExp(r'^([IVXLCDM]+\.\s*)(.*)$', caseSensitive: false).firstMatch(t);
    if (prefixMatch != null) {
      final prefix = prefixMatch.group(1)!.toUpperCase();
      final rest = prefixMatch.group(2)!;
      return '$prefix${_toTitleCase(rest)}';
    } else {
      return _toTitleCase(t);
    }
  }

  static String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    final upperCount = text.replaceAll(RegExp(r'[^A-Z]'), '').length;
    final lowerCount = text.replaceAll(RegExp(r'[^a-z]'), '').length;
    final shouldTitleCase = (upperCount > 0 && lowerCount == 0) ||
        (upperCount >= lowerCount && upperCount >= 3);
    if (!shouldTitleCase) return text;

    const minorWords = {
      'a', 'an', 'the', 'and', 'but', 'or', 'for', 'nor', 'on', 'at', 'to', 'from', 'by', 'of', 'in', 'with'
    };
    final words = text.toLowerCase().split(' ');
    final result = <String>[];
    for (int i = 0; i < words.length; i++) {
      final w = words[i];
      if (w.isEmpty) continue;
      if (i == 0 || !minorWords.contains(w)) {
        result.add(w[0].toUpperCase() + w.substring(1));
      } else {
        result.add(w);
      }
    }
    return result.join(' ');
  }

  static TocPageMatch? parseTocPageToken(
    String rawToken, {
    bool hasContentsHeader = false,
    bool isContinuation = false,
  }) {
    final t = rawToken.trim();
    if (t.isEmpty) return null;

    final directNum = int.tryParse(t);
    if (directNum != null && directNum > 0 && directNum < 10000) {
      return TocPageMatch(pageNumber: directNum, isRoman: false, rawLabel: t);
    }

    final lower = t.toLowerCase();
    if (_romanMap.containsKey(lower)) {
      return TocPageMatch(
        pageNumber: _romanMap[lower]!,
        isRoman: true,
        rawLabel: t.toUpperCase(),
      );
    }

    // Roman OCR normalization:
    var normRoman = lower;
    if (RegExp(r'''[ivx][\\'"!]+$''').hasMatch(normRoman)) {
      if (normRoman.endsWith(r"i\'") ||
          normRoman.endsWith('i"') ||
          normRoman.endsWith("i'")) {
        normRoman = normRoman.replaceAll(RegExp(r'''i[\\'"!]+$'''), 'iv');
      } else {
        normRoman = normRoman.replaceAll(RegExp(r'''[\\'"!]+$'''), 'v');
      }
    }
    normRoman = normRoman.replaceAll(RegExp(r'[1l|!]'), 'i');

    if (_romanMap.containsKey(normRoman)) {
      return TocPageMatch(
        pageNumber: _romanMap[normRoman]!,
        isRoman: true,
        rawLabel: normRoman.toUpperCase(),
      );
    }

    // Arabic OCR digit repairs
    if (hasContentsHeader || isContinuation) {
      var normArabic = t;
      normArabic = normArabic.replaceAll(RegExp(r'^[;:]\)?'), '3');
      if (normArabic.toLowerCase() == 'sg' || normArabic == '5G' || normArabic == 'sG') {
        normArabic = '56';
      }
      normArabic = normArabic
          .replaceAll(RegExp(r'^[lr](\d+)'), '1\$1')
          .replaceAll(RegExp(r'(\d)[oO]'), '\$10')
          .replaceAll(RegExp(r'[oO](\d)'), '0\$1')
          .replaceAll(RegExp(r'(\d)[gG]'), '\$16')
          .replaceAll(RegExp(r'(\d)[sS]'), '\$15');

      final arabicNum = int.tryParse(normArabic);
      if (arabicNum != null && arabicNum > 0 && arabicNum < 10000) {
        return TocPageMatch(pageNumber: arabicNum, isRoman: false, rawLabel: normArabic);
      }
    }

    return null;
  }

  static TocDetectionResult analyzePage({
    required List<LineFragment> lines,
    required double bodyRight,
    required String rawPageText,
    int? pageNum,
    int? totalPages,
    bool isContinuation = false,
  }) {
    bool hasContentsHeader = false;
    for (int i = 0; i < lines.length && i < 4; i++) {
      if (contentsHeaderRe.hasMatch(lines[i].text.trim())) {
        hasContentsHeader = true;
        break;
      }
    }
    if (!hasContentsHeader) {
      final firstLines =
          rawPageText.toLowerCase().split('\n').take(4).join(' ');
      if (contentsHeaderRe.hasMatch(firstLines.trim())) {
        hasContentsHeader = true;
      }
    }

    // Only run TocDetector on pages in the first 15% of the book (or up to page 30)
    // OR pages with an explicit Contents / Table of Contents heading (S-1)
    if (pageNum != null && totalPages != null && totalPages > 0) {
      final isEarlyPage = pageNum <= 30 || pageNum <= (totalPages * 0.15).ceil();
      if (!isEarlyPage && !hasContentsHeader && !isContinuation) {
        return const TocDetectionResult(isToc: false, entries: []);
      }
    }

    final entries = <TocEntry>[];
    final romanPages = <int>[];
    final arabicPages = <int>[];

    final dotLeaderRe = RegExp(
      r'^(.+?\S)[.…](?:[.…\s]){1,}\s*(\S+)$',
      caseSensitive: false,
    );
    final spaceGapRe = RegExp(
      r'^(.+?\S)(?:\s{2,}|\t+)(\S+)$',
      caseSensitive: false,
    );
    final singleSpaceRe = RegExp(
      r'^(.+?\S)\s+(\S+)$',
    );
    final subheaderRe = RegExp(
      r'^(?:spring|summer|autumn|fall|winter|part|book|volume|section)\b',
      caseSensitive: false,
    );

    for (final line in lines) {
      final t = line.text.trim();
      if (t.isEmpty) continue;
      if (contentsHeaderRe.hasMatch(t)) continue;

      String? titleCandidate;
      String? pageCandidate;

      final dotMatch = dotLeaderRe.firstMatch(t);
      if (dotMatch != null) {
        titleCandidate = dotMatch.group(1)!.trim();
        pageCandidate = dotMatch.group(2)!.trim();
      } else {
        final spaceMatch = spaceGapRe.firstMatch(t);
        if (spaceMatch != null) {
          titleCandidate = spaceMatch.group(1)!.trim();
          pageCandidate = spaceMatch.group(2)!.trim();
        } else if (hasContentsHeader || isContinuation || (line.right >= 0.72 * bodyRight)) {
          final singleMatch = singleSpaceRe.firstMatch(t);
          if (singleMatch != null) {
            titleCandidate = singleMatch.group(1)!.trim();
            pageCandidate = singleMatch.group(2)!.trim();
          }
        }
      }

      if (titleCandidate != null && pageCandidate != null) {
        final pageMatch = parseTocPageToken(
          pageCandidate,
          hasContentsHeader: hasContentsHeader,
          isContinuation: isContinuation,
        );

        if (pageMatch != null) {
          final words = titleCandidate
              .split(RegExp(r'\s+'))
              .where((w) => w.isNotEmpty)
              .toList();

          final endsWithPeriod = RegExp(r'[.!?:;]$').hasMatch(titleCandidate);
          if (words.length <= 14 && !endsWithPeriod) {
            final cleanTitle = cleanTocTitle(titleCandidate);
            if (cleanTitle.isNotEmpty) {
              entries.add(TocEntry(
                title: cleanTitle,
                pageNumber: pageMatch.pageNumber,
                rawPageLabel: pageMatch.rawLabel,
                isRoman: pageMatch.isRoman,
                level: 2,
              ));
              if (pageMatch.isRoman) {
                romanPages.add(pageMatch.pageNumber);
              } else {
                arabicPages.add(pageMatch.pageNumber);
              }
              continue;
            }
          }
        }
      }

      // Recognize section subheaders inside a TOC page as level-1 TOC group headers
      if (hasContentsHeader && subheaderRe.hasMatch(t)) {
        final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.length <= 5 && !RegExp(r'[.!?:;]$').hasMatch(t)) {
          entries.add(TocEntry(
            title: t,
            pageNumber: 0,
            rawPageLabel: '',
            isRoman: false,
            level: 1,
          ));
        }
      }
    }

    bool checkMonotonic(List<int> pages) {
      if (pages.length < 2) return true;
      int strictlyIncreasingSteps = 0;
      for (int i = 0; i < pages.length - 1; i++) {
        if (pages[i + 1] >= pages[i]) {
          strictlyIncreasingSteps++;
        }
      }
      return (strictlyIncreasingSteps / (pages.length - 1)) >= 0.75;
    }

    final romanOk = checkMonotonic(romanPages);
    final arabicOk = checkMonotonic(arabicPages);
    final dualRegimeMonotonic = romanOk && arabicOk;

    final isToc = hasContentsHeader
        ? (entries.length >= 2)
        : (entries.length >= 4 && dualRegimeMonotonic);

    return TocDetectionResult(isToc: isToc, entries: entries);
  }
}

class LayoutProfile {
  final double bodyFontSize;
  final double linePitch;
  final double bodyLeft;
  final double bodyRight;
  final double indent;
  final bool usesIndent;
  final bool hasTwoColumns;
  final double columnGutterLeft;
  final double columnGutterRight;

  const LayoutProfile({
    required this.bodyFontSize,
    required this.linePitch,
    required this.bodyLeft,
    required this.bodyRight,
    required this.indent,
    required this.usesIndent,
    this.hasTwoColumns = false,
    this.columnGutterLeft = 0.0,
    this.columnGutterRight = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'bodyFontSize': bodyFontSize,
    'linePitch': linePitch,
    'bodyLeft': bodyLeft,
    'bodyRight': bodyRight,
    'indent': indent,
    'usesIndent': usesIndent,
    'hasTwoColumns': hasTwoColumns,
    'columnGutterLeft': columnGutterLeft,
    'columnGutterRight': columnGutterRight,
  };

  factory LayoutProfile.fromJson(Map<String, dynamic> json) => LayoutProfile(
    bodyFontSize: (json['bodyFontSize'] as num?)?.toDouble() ?? 12.0,
    linePitch: (json['linePitch'] as num?)?.toDouble() ?? 14.0,
    bodyLeft: (json['bodyLeft'] as num?)?.toDouble() ?? 54.0,
    bodyRight: (json['bodyRight'] as num?)?.toDouble() ?? 550.0,
    indent: (json['indent'] as num?)?.toDouble() ?? 0.0,
    usesIndent: json['usesIndent'] as bool? ?? false,
    hasTwoColumns: json['hasTwoColumns'] as bool? ?? false,
    columnGutterLeft: (json['columnGutterLeft'] as num?)?.toDouble() ?? 0.0,
    columnGutterRight: (json['columnGutterRight'] as num?)?.toDouble() ?? 0.0,
  );

  factory LayoutProfile.compute(Map<int, List<LineFragment>> pageLinesMap) {
    final allLines = <LineFragment>[];
    for (final lines in pageLinesMap.values) {
      allLines.addAll(lines);
    }
    if (allLines.isEmpty) {
      return const LayoutProfile(
        bodyFontSize: 12.0,
        linePitch: 14.0,
        bodyLeft: 54.0,
        bodyRight: 550.0,
        indent: 0.0,
        usesIndent: false,
      );
    }

    // 1. bodyFontSize: mode of fontSize across all lines (bucketed to 0.5pt)
    final fontCounts = <double, int>{};
    for (final l in allLines) {
      if (l.fontSize <= 0) continue;
      final bucket = (l.fontSize * 2).round() / 2.0;
      fontCounts[bucket] = (fontCounts[bucket] ?? 0) + 1;
    }
    double bodyFontSize = 12.0;
    int maxFontCount = 0;
    for (final e in fontCounts.entries) {
      if (e.value > maxFontCount) {
        maxFontCount = e.value;
        bodyFontSize = e.key;
      }
    }

    // 2. linePitch: median of (next.top - curr.top) for consecutive body-sized lines
    final pitches = <double>[];
    for (final lines in pageLinesMap.values) {
      for (int i = 0; i < lines.length - 1; i++) {
        final curr = lines[i];
        final next = lines[i + 1];
        if ((curr.fontSize - bodyFontSize).abs() <= 0.5 &&
            (next.fontSize - bodyFontSize).abs() <= 0.5) {
          final diff = next.top - curr.top;
          if (diff > 0.5 * bodyFontSize && diff <= 3.0 * bodyFontSize) {
            pitches.add(diff);
          }
        }
      }
    }
    pitches.sort();
    final double linePitch = pitches.isNotEmpty
        ? pitches[pitches.length ~/ 2]
        : bodyFontSize * 1.25;

    // 3. Two-Column XY-Cut Detection:
    bool hasTwoCols = false;
    double gutterLeft = 0.0;
    double gutterRight = 0.0;
    if (allLines.length >= 20) {
      final minLeft = allLines.map((l) => l.left).reduce(min);
      final maxRight = allLines.map((l) => l.right).reduce(max);
      final pageWidthEst = maxRight - minLeft;
      if (pageWidthEst > 200) {
        final mid = minLeft + pageWidthEst * 0.5;
        final col1Lines =
            allLines.where((l) => l.right <= mid + bodyFontSize).length;
        final col2Lines =
            allLines.where((l) => l.left >= mid - bodyFontSize).length;
        if (col1Lines / allLines.length >= 0.35 &&
            col2Lines / allLines.length >= 0.35) {
          hasTwoCols = true;
          gutterLeft = mid - bodyFontSize;
          gutterRight = mid + bodyFontSize;
        }
      }
    }

    // 4. bodyLeft & bodyRight: mode of line.left and 95th percentile of line.right
    final leftCounts = <double, int>{};
    final rights = <double>[];
    for (final l in allLines) {
      if ((l.fontSize - bodyFontSize).abs() <= 1.0) {
        final bLeft = (l.left).roundToDouble();
        leftCounts[bLeft] = (leftCounts[bLeft] ?? 0) + 1;
        rights.add(l.right);
      }
    }
    double bodyLeft = 54.0;
    int maxLeftCount = 0;
    for (final e in leftCounts.entries) {
      if (e.value > maxLeftCount) {
        maxLeftCount = e.value;
        bodyLeft = e.key;
      }
    }
    rights.sort();
    final double bodyRight = rights.isNotEmpty
        ? rights[(rights.length * 0.95).floor().clamp(0, rights.length - 1)]
        : 550.0;

    // 5. indent: mode of (line.left - bodyLeft) among lines indented by 1em..4em
    final indentedDiffs = <double, int>{};
    int indentedLinesCount = 0;
    for (final l in allLines) {
      final diff = l.left - bodyLeft;
      if (diff >= bodyFontSize && diff <= 4.0 * bodyFontSize) {
        indentedLinesCount++;
        final bDiff = (diff).roundToDouble();
        indentedDiffs[bDiff] = (indentedDiffs[bDiff] ?? 0) + 1;
      }
    }
    final bool usesIndent = allLines.isNotEmpty &&
        (indentedLinesCount / allLines.length >= 0.08);
    double indent = 0.0;
    if (usesIndent && indentedDiffs.isNotEmpty) {
      int maxIndCount = 0;
      for (final e in indentedDiffs.entries) {
        if (e.value > maxIndCount) {
          maxIndCount = e.value;
          indent = e.key;
        }
      }
    }

    return LayoutProfile(
      bodyFontSize: bodyFontSize,
      linePitch: linePitch,
      bodyLeft: bodyLeft,
      bodyRight: bodyRight,
      indent: indent,
      usesIndent: usesIndent,
      hasTwoColumns: hasTwoCols,
      columnGutterLeft: gutterLeft,
      columnGutterRight: gutterRight,
    );
  }
}

class PageLayoutProfile extends LayoutProfile {
  final double pageBodyLeft;
  final double pageBodyRight;
  final bool isRaggedRight;

  const PageLayoutProfile({
    required super.bodyFontSize,
    required super.linePitch,
    required this.pageBodyLeft,
    required this.pageBodyRight,
    required super.indent,
    required super.usesIndent,
    this.isRaggedRight = false,
    super.hasTwoColumns = false,
    super.columnGutterLeft = 0.0,
    super.columnGutterRight = 0.0,
  }) : super(
          bodyLeft: pageBodyLeft,
          bodyRight: pageBodyRight,
        );

  factory PageLayoutProfile.compute({
    required List<LineFragment> lines,
    LayoutProfile? globalProfile,
  }) {
    if (lines.isEmpty) {
      final fallbackFontSize = globalProfile?.bodyFontSize ?? 12.0;
      final fallbackLinePitch = globalProfile?.linePitch ?? 14.0;
      final fallbackLeft = globalProfile?.bodyLeft ?? 54.0;
      final fallbackRight = globalProfile?.bodyRight ?? 550.0;
      return PageLayoutProfile(
        bodyFontSize: fallbackFontSize,
        linePitch: fallbackLinePitch,
        pageBodyLeft: fallbackLeft,
        pageBodyRight: fallbackRight,
        indent: globalProfile?.indent ?? 0.0,
        usesIndent: globalProfile?.usesIndent ?? false,
        isRaggedRight: false,
        hasTwoColumns: globalProfile?.hasTwoColumns ?? false,
        columnGutterLeft: globalProfile?.columnGutterLeft ?? 0.0,
        columnGutterRight: globalProfile?.columnGutterRight ?? 0.0,
      );
    }

    final bodyFontSize = globalProfile?.bodyFontSize ?? () {
      final fontCounts = <double, int>{};
      for (final l in lines) {
        if (l.fontSize <= 0) continue;
        final bucket = (l.fontSize * 2).round() / 2.0;
        fontCounts[bucket] = (fontCounts[bucket] ?? 0) + 1;
      }
      double bestFont = 12.0;
      int maxCnt = 0;
      for (final e in fontCounts.entries) {
        if (e.value > maxCnt) {
          maxCnt = e.value;
          bestFont = e.key;
        }
      }
      return bestFont;
    }();

    final linePitch = globalProfile?.linePitch ?? () {
      final pitches = <double>[];
      for (int i = 0; i < lines.length - 1; i++) {
        final curr = lines[i];
        final next = lines[i + 1];
        if ((curr.fontSize - bodyFontSize).abs() <= 0.5 &&
            (next.fontSize - bodyFontSize).abs() <= 0.5) {
          final diff = next.top - curr.top;
          if (diff > 0.5 * bodyFontSize && diff <= 3.0 * bodyFontSize) {
            pitches.add(diff);
          }
        }
      }
      pitches.sort();
      return pitches.isNotEmpty
          ? pitches[pitches.length ~/ 2]
          : bodyFontSize * 1.25;
    }();

    // 1. pageBodyLeft: 10th percentile / mode of line.left on this page (S-6, P2-01)
    final bodyLines = lines.where((l) => (l.fontSize - bodyFontSize).abs() <= 1.0).toList();
    final lefts = (bodyLines.isNotEmpty ? bodyLines : lines).map((l) => l.left).toList()..sort();
    final double pageBodyLeft = lefts.isNotEmpty
        ? lefts[(lefts.length * 0.10).floor().clamp(0, lefts.length - 1)]
        : 54.0;

    // 2. pageBodyRight: 95th percentile of line.right on this page
    final rights = (bodyLines.isNotEmpty ? bodyLines : lines).map((l) => l.right).toList()..sort();
    final double pageBodyRight = rights.isNotEmpty
        ? rights[(rights.length * 0.95).floor().clamp(0, rights.length - 1)]
        : 550.0;

    // 3. Two-column detection per page (>= 16 lines, both bands >= 35%)
    bool hasTwoCols = false;
    double gutterLeft = 0.0;
    double gutterRight = 0.0;
    if (lines.length >= 16) {
      final minLeft = lines.map((l) => l.left).reduce(min);
      final maxRight = lines.map((l) => l.right).reduce(max);
      final pageWidthEst = maxRight - minLeft;
      if (pageWidthEst > 200) {
        final mid = minLeft + pageWidthEst * 0.5;
        final col1Lines = lines.where((l) => l.right <= mid + bodyFontSize).length;
        final col2Lines = lines.where((l) => l.left >= mid - bodyFontSize).length;
        if (col1Lines / lines.length >= 0.35 && col2Lines / lines.length >= 0.35) {
          hasTwoCols = true;
          gutterLeft = mid - bodyFontSize;
          gutterRight = mid + bodyFontSize;
        }
      }
    }

    // 4. Ragged-right detection: < 50% reaching 0.90 * pageBodyRight (S-6, S-7)
    int reachingRightCount = 0;
    for (final l in (bodyLines.isNotEmpty ? bodyLines : lines)) {
      if (l.right >= 0.90 * pageBodyRight) {
        reachingRightCount++;
      }
    }
    final totalBodyLines = bodyLines.isNotEmpty ? bodyLines.length : lines.length;
    final bool isRaggedRight = totalBodyLines >= 4 &&
        (reachingRightCount / totalBodyLines < 0.50);

    // 5. Indent per page: lines where line.left - pageBodyLeft >= 0.8 * bodyFontSize && <= 4.5 * bodyFontSize
    int indentedCount = 0;
    final indDiffs = <double, int>{};
    for (final l in lines) {
      final diff = l.left - pageBodyLeft;
      if (diff >= 0.8 * bodyFontSize && diff <= 4.5 * bodyFontSize) {
        indentedCount++;
        final bDiff = diff.roundToDouble();
        indDiffs[bDiff] = (indDiffs[bDiff] ?? 0) + 1;
      }
    }
    final bool usesIndent = lines.isNotEmpty && (indentedCount / lines.length >= 0.08);
    double indent = 0.0;
    if (usesIndent && indDiffs.isNotEmpty) {
      int maxInd = 0;
      for (final e in indDiffs.entries) {
        if (e.value > maxInd) {
          maxInd = e.value;
          indent = e.key;
        }
      }
    }

    return PageLayoutProfile(
      bodyFontSize: bodyFontSize,
      linePitch: linePitch,
      pageBodyLeft: pageBodyLeft,
      pageBodyRight: pageBodyRight,
      indent: indent,
      usesIndent: usesIndent,
      isRaggedRight: isRaggedRight,
      hasTwoColumns: hasTwoCols,
      columnGutterLeft: gutterLeft,
      columnGutterRight: gutterRight,
    );
  }
}

class StructureResolver {
  static int _countWordsStatic(String text) {
    int count = 0;
    bool inWord = false;
    for (int i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) <= 32) {
        inWord = false;
      } else if (!inWord) {
        inWord = true;
        count++;
      }
    }
    return count;
  }

  static bool _hasCompleteProseSentence(List<LineFragment> lines, String rawText) {
    const functionWords = {
      'the', 'of', 'and', 'to', 'a', 'in', 'that', 'is', 'was', 'for', 'it', 'with', 'as', 'by', 'on', 'this', 'from', 'at'
    };
    for (final l in lines) {
      final t = l.text.trim();
      if (RegExp(r'[.!?]$').hasMatch(t)) {
        final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.length >= 8) {
          final hasFunctionWord = words.any((w) => functionWords.contains(w.toLowerCase()));
          if (hasFunctionWord) return true;
        }
      }
    }
    final sentences = rawText.split(RegExp(r'(?<=[.!?])\s+'));
    for (final s in sentences) {
      final trimmed = s.trim();
      if (RegExp(r'[.!?]$').hasMatch(trimmed)) {
        final words = trimmed.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        if (words.length >= 8) {
          final hasFunctionWord = words.any((w) => functionWords.contains(w.toLowerCase()));
          if (hasFunctionWord) return true;
        }
      }
    }
    return false;
  }

  static List<SectionRole> smoothRolesForWindow({
    required int startPage,
    required int endPage,
    required int totalPages,
    required Map<int, List<LineFragment>> pageLinesMap,
    required Map<int, String> pageRawTextMap,
    required Map<int, String> bookmarks,
    required Set<int> tocPages,
    required Map<int, Object> explicitHeadingMap,
  }) {
    final windowLength = (endPage - startPage + 1).clamp(0, totalPages);
    if (windowLength <= 0) return const [];

    final roles = <SectionRole>[];
    for (int pageNum = startPage; pageNum <= endPage; pageNum++) {
      final lines = pageLinesMap[pageNum] ?? const [];
      final rawText = (pageRawTextMap[pageNum] ?? '').toLowerCase();
      final words = _countWordsStatic(rawText);
      final Object? headingVal = explicitHeadingMap[pageNum];
      final String heading = (headingVal is List
              ? headingVal.join(' ')
              : headingVal?.toString() ?? bookmarks[pageNum] ?? '')
          .toLowerCase();

      final isToc = tocPages.contains(pageNum);
      final hasFrontMarkers = RegExp(
              r'(?:copyright|©|all rights reserved|isbn|library of congress|cataloging|printed in|published by)\b',
              caseSensitive: false)
          .hasMatch(rawText);

      int upperLines = 0;
      for (final l in lines) {
        final t = l.text.trim();
        if (t.isNotEmpty && t == t.toUpperCase() && t.length > 3) {
          upperLines++;
        }
      }
      final upperRatio = lines.isEmpty ? 0.0 : upperLines / lines.length;
      final avgWordsPerLine = lines.isEmpty ? 0.0 : words / lines.length;
      final frontScore = DocumentIngestionPipeline.scoreFrontOrBackMatter(lines, rawText);
      final hasProseSentence = _hasCompleteProseSentence(lines, rawText);

      final isEarlyPage = totalPages <= 30
          ? (pageNum <= (totalPages * 0.20).ceil())
          : (pageNum <= 30 || pageNum <= (totalPages * 0.15).ceil());
      final isNonProseMatter = isEarlyPage &&
          !hasProseSentence &&
          (upperRatio >= 0.45 ||
              frontScore >= 40 ||
              (avgWordsPerLine < 6.5 && (words < 40 || lines.length <= 8)));

      final bool isLatePage = totalPages > 4 && pageNum >= (totalPages * 0.75).floor();
      final hasBackHeading = RegExp(
              r'^(?:notes?|endnotes|index|bibliography|references|works cited|glossary|about the author|also by)\b',
              caseSensitive: false)
          .hasMatch(heading);
      final hasBackLine = lines.any((l) {
        final t = l.text.trim();
        final wCount = _countWordsStatic(t);
        return wCount <= 10 &&
            RegExp(r'^(?:notes?|endnotes|index|bibliography|references|works cited|glossary|about the author|also by)\b',
                    caseSensitive: false)
                .hasMatch(t);
      });

      int indexEntryCount = 0;
      for (final l in lines) {
        if (RegExp(r'^[A-Za-z][^,]{1,40},\s\d').hasMatch(l.text.trim())) {
          indexEntryCount++;
        }
      }
      final bool isIndexDense =
          lines.length >= 8 && (indexEntryCount / lines.length >= 0.40);
      final bool hasBackMarkers = isLatePage &&
          (hasBackHeading || (hasBackLine && (isIndexDense || words < 120)));

      final hasReadableFrontHeader = RegExp(
                  r'\b(preface|foreword|introduction|prologue|acknowledgments)\b',
                  caseSensitive: false)
              .hasMatch(heading) ||
          lines.any((l) {
            final t = l.text.trim();
            final wCount = _countWordsStatic(t);
            return wCount <= 10 &&
                RegExp(r'^(?:preface|foreword|introduction|prologue|acknowledgments)\b',
                        caseSensitive: false)
                    .hasMatch(t);
          });

      if (pageNum <= (totalPages * 0.20).ceil() || isEarlyPage) {
        if (isToc) {
          roles.add(SectionRole.toc);
        } else if (hasReadableFrontHeader && !isNonProseMatter) {
          roles.add(SectionRole.preface);
        } else if (hasFrontMarkers || isNonProseMatter) {
          roles.add(hasFrontMarkers && rawText.contains('copyright')
              ? SectionRole.copyright
              : SectionRole.titlePage);
        } else {
          roles.add(SectionRole.chapter);
        }
      } else if (isLatePage && (hasBackMarkers || isIndexDense)) {
        if (heading.contains('index') || isIndexDense) {
          roles.add(SectionRole.bookIndex);
        } else if (heading.contains('glossary')) {
          roles.add(SectionRole.glossary);
        } else if (heading.contains('bibliography') || heading.contains('references')) {
          roles.add(SectionRole.bibliography);
        } else {
          roles.add(SectionRole.notes);
        }
      } else {
        roles.add(SectionRole.chapter);
      }
    }
    return roles;
  }

  static List<SectionRole> smoothRoles({
    required int totalPages,
    required Map<int, List<LineFragment>> pageLinesMap,
    required Map<int, String> pageRawTextMap,
    required Map<int, String> bookmarks,
    required Set<int> tocPages,
    required Map<int, Object> explicitHeadingMap,
  }) {
    if (totalPages <= 0) return const [];
    const numStates = 5;

    // Emissions: E[p][s]
    final emissions = List.generate(totalPages, (p) {
      final pageNum = p + 1;
      final lines = pageLinesMap[pageNum] ?? const [];
      final rawText = (pageRawTextMap[pageNum] ?? '').toLowerCase();
      final words =
          rawText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      final Object? headingVal = explicitHeadingMap[pageNum];
      final String heading = (headingVal is List
              ? headingVal.join(' ')
              : headingVal?.toString() ?? bookmarks[pageNum] ?? '')
          .toLowerCase();

      final isToc = tocPages.contains(pageNum);
      final hasFrontMarkers = RegExp(
              r'(?:copyright|©|all rights reserved|isbn|library of congress|cataloging|printed in|published by)\b',
              caseSensitive: false)
          .hasMatch(rawText);

      // S-2: Back markers require >= 2 independent signals in final 25% of book
      final bool isLatePage = totalPages > 4 && pageNum >= (totalPages * 0.75).floor();
      final hasBackHeading = RegExp(
              r'^(?:notes?|endnotes|index|bibliography|references|works cited|glossary|about the author|also by)\b',
              caseSensitive: false)
          .hasMatch(heading);
      final hasBackLine = lines.any((l) {
        final t = l.text.trim();
        final wCount = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        return wCount <= 10 &&
            RegExp(r'^(?:notes?|endnotes|index|bibliography|references|works cited|glossary|about the author|also by)\b',
                    caseSensitive: false)
                .hasMatch(t);
      });

      int indexEntryCount = 0;
      for (final l in lines) {
        if (RegExp(r'^[A-Za-z][^,]{1,40},\s\d').hasMatch(l.text.trim())) {
          indexEntryCount++;
        }
      }
      final bool isIndexDense =
          lines.length >= 8 && (indexEntryCount / lines.length >= 0.40);
      final bool hasBackMarkers = isLatePage &&
          (hasBackHeading || (hasBackLine && (isIndexDense || words < 120)));

      // S-2: Readable front markers (preface, foreword, introduction, prologue, acknowledgments)
      final hasReadableFrontHeader = RegExp(
                  r'\b(preface|foreword|introduction|prologue|acknowledgments)\b',
                  caseSensitive: false)
              .hasMatch(heading) ||
          lines.any((l) {
            final t = l.text.trim();
            final wCount = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
            return wCount <= 10 &&
                RegExp(r'^(?:preface|foreword|introduction|prologue|acknowledgments)\b',
                        caseSensitive: false)
                    .hasMatch(t);
          });

      // S-2: Chapter headers restricted to true headings (not multiline body sentences)
      final hasChapterHeader = RegExp(
                  r'\b(?:chapter|part)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b',
                  caseSensitive: false)
              .hasMatch(heading) ||
          lines.any((l) {
            final t = l.text.trim();
            final wCount = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
            return wCount <= 10 &&
                RegExp(r'^(?:chapter|part|book)\s+(?:\d+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)\b',
                        caseSensitive: false)
                    .hasMatch(t);
          });

      int upperLines = 0;
      for (final l in lines) {
        final t = l.text.trim();
        if (t.isNotEmpty && t == t.toUpperCase() && t.length > 3) {
          upperLines++;
        }
      }
      final upperRatio = lines.isEmpty ? 0.0 : upperLines / lines.length;
      final avgWordsPerLine = lines.isEmpty ? 0.0 : words / lines.length;
      final frontScore = DocumentIngestionPipeline.scoreFrontOrBackMatter(lines, rawText);
      final hasProseSentence = _hasCompleteProseSentence(lines, rawText);

      final isEarlyPage = totalPages <= 30
          ? (pageNum <= (totalPages * 0.20).ceil())
          : (pageNum <= 30 || pageNum <= (totalPages * 0.15).ceil());
      final isNonProseMatter = isEarlyPage &&
          !hasProseSentence &&
          (upperRatio >= 0.45 ||
              frontScore >= 40 ||
              (avgWordsPerLine < 6.5 && (words < 40 || lines.length <= 8)));

      final e = List<double>.filled(numStates, 0.0);

      if (isToc) {
        e[1] = 0.0;
        e[0] = 50.0;
        e[2] = 50.0;
        e[3] = 60.0;
        e[4] = 70.0;
      } else if (hasReadableFrontHeader && !isNonProseMatter) {
        e[2] = 0.0;
        e[0] = 40.0;
        e[1] = 40.0;
        e[3] = 30.0;
        e[4] = 50.0;
      } else if (hasFrontMarkers || isNonProseMatter) {
        e[0] = 0.0;
        e[1] = 40.0;
        e[2] = 40.0;
        e[3] = 60.0;
        e[4] = 80.0;
      } else if (hasBackMarkers || (isLatePage && isIndexDense)) {
        e[4] = 0.0;
        e[0] = 70.0;
        e[1] = 70.0;
        e[2] = 60.0;
        e[3] = 50.0;
      } else if (hasChapterHeader) {
        e[3] = 0.0;
        e[0] = 50.0;
        e[1] = 50.0;
        e[2] = 30.0;
        e[4] = 40.0;
      } else {
        if (words >= 80) {
          e[0] = 25.0;
          e[1] = 30.0;
          e[2] = 2.0; // S-2: Sticky readable front
          e[3] = 2.0; // Body
          e[4] = 8.0;
        } else {
          e[0] = 2.0;
          e[1] = 10.0;
          e[2] = 8.0;
          e[3] = 10.0;
          e[4] = 6.0;
        }
      }
      return e;
    });

    final v = List.generate(
        totalPages, (_) => List<double>.filled(numStates, double.infinity));
    final bp = List.generate(
        totalPages, (_) => List<int>.filled(numStates, 0));

    const initCost = [0.0, 2.0, 6.0, 15.0, 40.0];
    for (int s = 0; s < numStates; s++) {
      v[0][s] = initCost[s] + emissions[0][s];
    }

    for (int p = 1; p < totalPages; p++) {
      for (int curr = 0; curr < numStates; curr++) {
        double minPrevCost = double.infinity;
        int bestPrev = 0;
        for (int prev = 0; prev <= curr; prev++) {
          final transCost = (prev == curr)
              ? 0.0
              : ((prev == 2 && curr == 3) ? 4.0 : 1.0); // S-2: 2->3 transition cost = 4.0
          final total = v[p - 1][prev] + transCost;
          if (total < minPrevCost) {
            minPrevCost = total;
            bestPrev = prev;
          }
        }
        v[p][curr] = minPrevCost + emissions[p][curr];
        bp[p][curr] = bestPrev;
      }
    }

    final statePath = List<int>.filled(totalPages, 3);
    double minFinal = double.infinity;
    int bestFinal = 3;
    for (int s = 0; s < numStates; s++) {
      if (v[totalPages - 1][s] < minFinal) {
        minFinal = v[totalPages - 1][s];
        bestFinal = s;
      }
    }
    statePath[totalPages - 1] = bestFinal;
    for (int p = totalPages - 1; p > 0; p--) {
      statePath[p - 1] = bp[p][statePath[p]];
    }

    SectionRole activeReadableRole = SectionRole.preface;
    final result = <SectionRole>[];

    for (int p = 0; p < totalPages; p++) {
      final pageNum = p + 1;
      final macro = statePath[p];
      final rawText = (pageRawTextMap[pageNum] ?? '').toLowerCase();
      final Object? headingVal = explicitHeadingMap[pageNum];
      final String heading = (headingVal is List
              ? headingVal.join(' ')
              : headingVal?.toString() ?? bookmarks[pageNum] ?? '')
          .toLowerCase();

      if (macro == 0) {
        if (rawText.contains('copyright') ||
            rawText.contains('©') ||
            rawText.contains('isbn')) {
          result.add(SectionRole.copyright);
        } else if (rawText.contains('dedicat')) {
          result.add(SectionRole.dedication);
        } else if (rawText.contains('praise')) {
          result.add(SectionRole.praise);
        } else if (p == 0) {
          result.add(SectionRole.cover);
        } else {
          result.add(SectionRole.titlePage);
        }
      } else if (macro == 1) {
        result.add(SectionRole.toc);
      } else if (macro == 2) {
        if (heading.contains('preface') || rawText.startsWith('preface')) {
          activeReadableRole = SectionRole.preface;
        } else if (heading.contains('foreword') ||
            rawText.startsWith('foreword')) {
          activeReadableRole = SectionRole.foreword;
        } else if (heading.contains('intro') ||
            rawText.startsWith('introduction')) {
          activeReadableRole = SectionRole.introduction;
        } else if (heading.contains('prologue') ||
            rawText.startsWith('prologue')) {
          activeReadableRole = SectionRole.prologue;
        } else if (heading.contains('ack') ||
            rawText.startsWith('acknowledg')) {
          activeReadableRole = SectionRole.acknowledgments;
        }
        result.add(activeReadableRole);
      } else if (macro == 3) {
        if (heading.contains('part ') || rawText.startsWith('part ')) {
          result.add(SectionRole.part);
        } else if (heading.contains('epilogue') ||
            rawText.startsWith('epilogue')) {
          result.add(SectionRole.epilogue);
        } else if (heading.contains('afterword') ||
            rawText.startsWith('afterword')) {
          result.add(SectionRole.afterword);
        } else {
          result.add(SectionRole.chapter);
        }
      } else {
        if (heading.contains('notes') ||
            rawText.contains('endnotes') ||
            rawText.startsWith('notes')) {
          result.add(SectionRole.notes);
        } else if (heading.contains('biblio') ||
            rawText.contains('references') ||
            rawText.contains('works cited')) {
          result.add(SectionRole.bibliography);
        } else if (heading.contains('index') || rawText.startsWith('index')) {
          result.add(SectionRole.bookIndex);
        } else if (heading.contains('glossary') ||
            rawText.startsWith('glossary')) {
          result.add(SectionRole.glossary);
        } else if (heading.contains('about the author') ||
            rawText.contains('about the author')) {
          result.add(SectionRole.aboutAuthor);
        } else {
          result.add(SectionRole.appendix);
        }
      }
    }

    return result;
  }
}
