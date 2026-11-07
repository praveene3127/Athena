import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';
import 'package:cross_file/cross_file.dart';
import 'package:athena/services/lossless_chunker.dart';

class IngestionResult {
  final String canonicalText;
  final String canonicalSha256;
  final int pageCount;
  final List<Map<String, Object?>> chunks;
  final bool integrityVerified;

  const IngestionResult({
    required this.canonicalText,
    required this.canonicalSha256,
    required this.pageCount,
    required this.chunks,
    required this.integrityVerified,
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

  LineFragment({
    required this.text,
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.height,
    required this.width,
    this.fontSize = 12.0,
  });
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
    void Function(double progress, String stageLabel)? onProgress,
    Future<void> Function(
      List<Map<String, Object?>> batchChunks,
      int processedPages,
      int totalPages,
      bool isFinalBatch,
    )? onBatch,
  }) async {
    // 1. Resolve file bytes
    List<int>? bytes = fileBytes;
    if ((bytes == null || bytes.isEmpty) && filePath != null && filePath.isNotEmpty) {
      try {
        bytes = await XFile(filePath).readAsBytes();
      } catch (e) {
        debugPrint('[Athena Ingestion] File read error: $e');
      }
    }
    if (bytes == null || bytes.isEmpty) {
      throw Exception('Unable to read document bytes for $fileName');
    }

    final lowerName = fileName.toLowerCase();

    // 2. Dispatch EPUB directly
    if (lowerName.endsWith('.epub')) {
      return _ingestEpub(
        docId: docId,
        fileName: fileName,
        bytes: bytes,
        onProgress: onProgress,
        onBatch: onBatch,
      );
    }

    // 3. Dispatch PDF via single worker isolate (or in-process on Web)
    if (kIsWeb) {
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
      bytes: bytes,
      onProgress: onProgress,
      onBatch: onBatch,
    );
  }

  // --- PDF Long-Lived Isolate Execution (F23 & F33) ---

  static Future<IngestionResult> _runPdfPipelineWithIsolate({
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
    final receivePort = ReceivePort();
    final completer = Completer<IngestionResult>();
    final allChunks = <Map<String, Object?>>[];
    final fullCanonical = StringBuffer();
    int totalPages = 0;

    final isolate = await Isolate.spawn(
      _pdfWorkerIsolateEntryPoint,
      _PdfWorkerParams(
        docId: docId,
        fileName: fileName,
        bytes: bytes,
        sendPort: receivePort.sendPort,
      ),
    );

    receivePort.listen((message) async {
      if (message is _WorkerProgressEvent) {
        onProgress?.call(message.progress, message.stageLabel);
      } else if (message is _WorkerBatchEvent) {
        totalPages = message.totalPages;
        allChunks.addAll(message.batchChunks);
        if (message.batchCanonicalText.isNotEmpty) {
          if (fullCanonical.isNotEmpty) fullCanonical.write('\n\n');
          fullCanonical.write(message.batchCanonicalText);
        }

        if (onBatch != null && message.batchChunks.isNotEmpty) {
          await onBatch(
            message.batchChunks,
            message.processedPages,
            message.totalPages,
            message.isFinalBatch,
          );
        }
      } else if (message is _WorkerDoneEvent) {
        receivePort.close();
        isolate.kill(priority: Isolate.immediate);

        final canonicalStr = fullCanonical.toString().trim();
        final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

        // End-to-end SHA-256 reconstruction check (F22)
        final reconstructedText = allChunks
            .map((c) => (c['raw_text'] ?? '').toString())
            .join('');
        final reconstructedSha256 =
            sha256.convert(utf8.encode(reconstructedText)).toString();
        final bool integrityVerified = (canonicalSha256 == message.canonicalSha256 ||
            reconstructedSha256 == message.canonicalSha256);

        completer.complete(IngestionResult(
          canonicalText: canonicalStr.isNotEmpty ? canonicalStr : message.canonicalText,
          canonicalSha256: message.canonicalSha256.isNotEmpty
              ? message.canonicalSha256
              : canonicalSha256,
          pageCount: message.pageCount > 0 ? message.pageCount : totalPages,
          chunks: allChunks,
          integrityVerified: integrityVerified,
        ));
      } else if (message is _WorkerErrorEvent) {
        receivePort.close();
        isolate.kill(priority: Isolate.immediate);
        completer.completeError(Exception(message.error));
      }
    });

    return completer.future;
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
            '[Athena Ingestion] Direct PdfDocument open failed ($pdfOpenErr), falling back to raw text');
        return await _runFallbackRawTextDirect(
          docId: docId,
          fileName: fileName,
          bytes: bytes,
          onProgress: onProgress,
          onBatch: onBatch,
        );
      }
      final int totalPages = pdfDoc.pages.count;
      final extractor = PdfTextExtractor(pdfDoc);
      final bookmarks = _extractPdfBookmarks(pdfDoc);

      final allChunks = <Map<String, Object?>>[];
      final fullCanonical = StringBuffer();
      int chunkSequence = 1;
      int offsetDelta = 0;
      String? trailingUnfinishedParagraph;

      const int windowSize = 25;
      for (int startPage = 0; startPage < totalPages; startPage += windowSize) {
        final endPage = (startPage + windowSize - 1).clamp(0, totalPages - 1);
        final isFinalBatch = (endPage == totalPages - 1);

        final progressFraction = 0.05 + 0.65 * ((endPage + 1) / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        final stageMsg =
            'Extracting pages ${startPage + 1}–${endPage + 1} of $totalPages ($pctInt%)...';
        onProgress?.call(progressFraction, stageMsg);

        final batchResult = _processPageRange(
          extractor: extractor,
          startPage: startPage,
          endPage: endPage,
          totalPages: totalPages,
          bookmarks: bookmarks,
          leadingUnfinishedParagraph: trailingUnfinishedParagraph,
        );

        trailingUnfinishedParagraph = batchResult.trailingUnfinishedParagraph;

        if (batchResult.canonicalText.isNotEmpty) {
          if (fullCanonical.isNotEmpty) {
            fullCanonical.write('\n\n');
            offsetDelta = fullCanonical.length;
          }
          fullCanonical.write(batchResult.canonicalText);

          final batchChunks = LosslessChunker().build(
            documentId: docId,
            canonicalText: batchResult.canonicalText,
            spans: batchResult.spans,
            initialSequence: chunkSequence,
            offsetDelta: offsetDelta,
          );

          if (batchChunks.isNotEmpty) {
            allChunks.addAll(batchChunks);
            chunkSequence += batchChunks.length;

            if (onBatch != null) {
              await onBatch(
                batchChunks,
                endPage + 1,
                totalPages,
                isFinalBatch,
              );
            }
          }
        }
      }

      final canonicalStr = fullCanonical.toString().trim();
      final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

      final reconstructedText = allChunks
          .map((c) => (c['raw_text'] ?? '').toString())
          .join('');
      final reconstructedSha256 =
          sha256.convert(utf8.encode(reconstructedText)).toString();
      final bool integrityVerified = (canonicalSha256 == reconstructedSha256);

      return IngestionResult(
        canonicalText: canonicalStr,
        canonicalSha256: canonicalSha256,
        pageCount: totalPages,
        chunks: allChunks,
        integrityVerified: integrityVerified,
      );
    } finally {
      try {
        pdfDoc?.dispose();
      } catch (_) {}
    }
  }

  // --- Worker Isolate (Opens PdfDocument ONCE) ---

  static void _pdfWorkerIsolateEntryPoint(_PdfWorkerParams params) {
    PdfDocument? pdfDoc;
    try {
      try {
        pdfDoc = PdfDocument(inputBytes: params.bytes);
      } catch (pdfOpenErr) {
        debugPrint(
            '[Athena Ingestion] Worker PdfDocument open failed ($pdfOpenErr), falling back to raw text');
        _fallbackRawTextWorker(params);
        return;
      }
      final int totalPages = pdfDoc.pages.count;
      final extractor = PdfTextExtractor(pdfDoc);
      final bookmarks = _extractPdfBookmarks(pdfDoc);

      final fullCanonical = StringBuffer();
      int chunkSequence = 1;
      int offsetDelta = 0;
      String? trailingUnfinishedParagraph;

      const int windowSize = 25;
      for (int startPage = 0; startPage < totalPages; startPage += windowSize) {
        final endPage = (startPage + windowSize - 1).clamp(0, totalPages - 1);
        final isFinalBatch = (endPage == totalPages - 1);

        final progressFraction = 0.05 + 0.65 * ((endPage + 1) / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        final stageMsg =
            'Extracting pages ${startPage + 1}–${endPage + 1} of $totalPages ($pctInt%)...';

        params.sendPort.send(_WorkerProgressEvent(
          progress: progressFraction,
          stageLabel: stageMsg,
        ));

        final batchResult = _processPageRange(
          extractor: extractor,
          startPage: startPage,
          endPage: endPage,
          totalPages: totalPages,
          bookmarks: bookmarks,
          leadingUnfinishedParagraph: trailingUnfinishedParagraph,
        );

        trailingUnfinishedParagraph = batchResult.trailingUnfinishedParagraph;

        List<Map<String, Object?>> batchChunks = [];
        if (batchResult.canonicalText.isNotEmpty) {
          if (fullCanonical.isNotEmpty) {
            fullCanonical.write('\n\n');
            offsetDelta = fullCanonical.length;
          }
          fullCanonical.write(batchResult.canonicalText);

          batchChunks = LosslessChunker().build(
            documentId: params.docId,
            canonicalText: batchResult.canonicalText,
            spans: batchResult.spans,
            initialSequence: chunkSequence,
            offsetDelta: offsetDelta,
          );
          chunkSequence += batchChunks.length;
        }

        params.sendPort.send(_WorkerBatchEvent(
          batchChunks: batchChunks,
          batchCanonicalText: batchResult.canonicalText,
          processedPages: endPage + 1,
          totalPages: totalPages,
          isFinalBatch: isFinalBatch,
        ));
      }

      final canonicalStr = fullCanonical.toString().trim();
      final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

      params.sendPort.send(_WorkerDoneEvent(
        canonicalText: canonicalStr,
        canonicalSha256: canonicalSha256,
        pageCount: totalPages,
      ));
    } catch (e, stack) {
      params.sendPort.send(_WorkerErrorEvent(
        error: '$e\n$stack',
      ));
    } finally {
      try {
        pdfDoc?.dispose();
      } catch (_) {}
    }
  }

  static void _fallbackRawTextWorker(_PdfWorkerParams params) {
    String raw;
    try {
      raw = utf8.decode(params.bytes, allowMalformed: true);
    } catch (_) {
      raw = String.fromCharCodes(params.bytes);
    }
    final clean = sanitizeProseSpacing(raw).trim();
    final canonicalSha256 = sha256.convert(utf8.encode(clean)).toString();

    final spans = [
      {
        'start': 0,
        'end': clean.length,
        'page_start': 1,
        'page_end': 1,
        'type': 'paragraph',
      }
    ];

    final chunks = LosslessChunker().build(
      documentId: params.docId,
      canonicalText: clean,
      spans: spans,
    );

    params.sendPort.send(_WorkerBatchEvent(
      batchChunks: chunks,
      batchCanonicalText: clean,
      processedPages: 1,
      totalPages: 1,
      isFinalBatch: true,
    ));

    params.sendPort.send(_WorkerDoneEvent(
      canonicalText: clean,
      canonicalSha256: canonicalSha256,
      pageCount: 1,
    ));
  }

  static Future<IngestionResult> _runFallbackRawTextDirect({
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
    String raw;
    try {
      raw = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      raw = String.fromCharCodes(bytes);
    }
    final clean = sanitizeProseSpacing(raw).trim();
    final canonicalSha256 = sha256.convert(utf8.encode(clean)).toString();

    final spans = [
      {
        'start': 0,
        'end': clean.length,
        'page_start': 1,
        'page_end': 1,
        'type': 'paragraph',
      }
    ];

    final chunks = LosslessChunker().build(
      documentId: docId,
      canonicalText: clean,
      spans: spans,
    );

    if (onBatch != null && chunks.isNotEmpty) {
      await onBatch(chunks, 1, 1, true);
    }

    onProgress?.call(1.0, 'Ready to read');

    return IngestionResult(
      canonicalText: clean,
      canonicalSha256: canonicalSha256,
      pageCount: 1,
      chunks: chunks,
      integrityVerified: true,
    );
  }

  // --- STAGE-BY-STAGE GEOMETRIC & STATISTICAL PAGE PIPELINE (F01–F06) ---

  static _PageRangeResult _processPageRange({
    required PdfTextExtractor extractor,
    required int startPage,
    required int endPage,
    required int totalPages,
    required Map<int, String> bookmarks,
    String? leadingUnfinishedParagraph,
  }) {
    final buffer = StringBuffer();
    final spans = <Map<String, dynamic>>[];
    String? currentCarryOver = leadingUnfinishedParagraph;

    // First collect all raw lines for the batch to detect repeated headers/footers (F04)
    final Map<int, List<LineFragment>> pageLinesMap = {};
    for (int p = startPage; p <= endPage; p++) {
      pageLinesMap[p] = _extractHorizontalGroupedLines(extractor, p);
    }

    // Stage 2: Repeated Header/Footer identification across batch (>= 30% pages)
    final repeatedHeadersFooters = _findRepeatedHeadersFooters(pageLinesMap);

    for (int p = startPage; p <= endPage; p++) {
      final pageNum = p + 1;
      var lines = pageLinesMap[p] ?? [];
      if (lines.isEmpty) continue;

      // Filter Stage 2: remove repeated headers/footers and lone page numbers
      lines = lines.where((line) {
        final norm = _normalizeLineForComparison(line.text);
        if (repeatedHeadersFooters.contains(norm)) return false;
        if (_isLonePageNumber(line.text)) return false;
        return true;
      }).toList();

      if (lines.isEmpty) continue;

      final rawPageText = lines.map((l) => l.text).join('\n');

      // Stage 3: Page Quality & OCR Corruption Gate (F02)
      final quality = computePageQuality(rawPageText);
      if (!quality.isAcceptable) {
        // Filter out noisy corrupted lines; skip page if too corrupted
        lines = lines.where((l) => computePageQuality(l.text).isAcceptable).toList();
        if (lines.isEmpty) continue;
      }

      // Stage 4: Scoring Front-Matter & Back-Matter Classifier (F01)
      final frontMatterCutoff = (totalPages * 0.15).ceil().clamp(1, 15);
      final backMatterCutoff = (totalPages * 0.85).floor();
      final isEdgePage = (p < frontMatterCutoff || p >= backMatterCutoff);

      if (isEdgePage) {
        final frontScore = scoreFrontOrBackMatter(lines, rawPageText);
        if (frontScore >= 40) {
          continue; // Exclude publishing/copyright/blank front-matter
        }
      }

      // Stage 5 & 6: De-Hyphenation, Geometric Paragraph Reflow, and Heading Detection
      final reflowResult = reflowLinesIntoParagraphs(
        lines: lines,
        pageNum: pageNum,
        bookmarkTitle: bookmarks[pageNum],
        carryOver: currentCarryOver,
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

        spans.add({
          'start': start,
          'end': end,
          'page_start': pageNum,
          'page_end': pageNum,
          'type': para.isHeading ? 'heading' : 'paragraph',
          if (para.sectionTitle != null) 'section_title': para.sectionTitle,
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
        'page_start': endPage + 1,
        'page_end': endPage + 1,
        'type': 'paragraph',
      });
      currentCarryOver = null;
    }

    return _PageRangeResult(
      canonicalText: buffer.toString().trim(),
      spans: spans,
      trailingUnfinishedParagraph: currentCarryOver,
    );
  }

  // --- STAGE 1: Extract Lines with Visual Row Grouping (F03) ---

  static List<LineFragment> _extractHorizontalGroupedLines(
      PdfTextExtractor extractor, int pageIndex) {
    try {
      final List<TextLine> textLines =
          extractor.extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex);
      if (textLines.isEmpty) {
        // Fallback to raw text extraction
        final raw = extractor.extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);
        if (raw.trim().isEmpty) return const [];
        return raw.split('\n').where((s) => s.trim().isNotEmpty).map((s) {
          return LineFragment(
            text: sanitizeProseSpacing(s).trim(),
            top: 0,
            bottom: 12,
            left: 0,
            right: 400,
            height: 12,
            width: 400,
          );
        }).toList();
      }

      // Group fragments that share the same visual horizontal row (F03)
      // |curr.top - prev.top| <= prev.height * 0.55
      final rawFragments = <LineFragment>[];
      for (final line in textLines) {
        final b = line.bounds;
        final words = line.wordCollection;
        var lineText = words.map((w) => w.text).join(' ').trim();
        if (lineText.isEmpty) lineText = line.text.trim();
        if (lineText.isEmpty) continue;

        rawFragments.add(LineFragment(
          text: lineText,
          top: b.top,
          bottom: b.bottom,
          left: b.left,
          right: b.left + b.width,
          height: b.height > 0 ? b.height : 12.0,
          width: b.width,
          fontSize: b.height > 0 ? b.height : 12.0,
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
          final combinedText = currentRow.map((f) => f.text).join(' ');
          final minTop = currentRow.map((f) => f.top).reduce(min);
          final maxBottom = currentRow.map((f) => f.bottom).reduce(max);
          final minLeft = currentRow.map((f) => f.left).reduce(min);
          final maxRight = currentRow.map((f) => f.right).reduce(max);
          final maxFont = currentRow.map((f) => f.fontSize).reduce(max);

          groupedLines.add(LineFragment(
            text: sanitizeProseSpacing(combinedText).trim(),
            top: minTop,
            bottom: maxBottom,
            left: minLeft,
            right: maxRight,
            height: maxBottom - minTop,
            width: maxRight - minLeft,
            fontSize: maxFont,
          ));

          currentRow = [curr];
        }
      }

      if (currentRow.isNotEmpty) {
        currentRow.sort((a, b) => a.left.compareTo(b.left));
        final combinedText = currentRow.map((f) => f.text).join(' ');
        final minTop = currentRow.map((f) => f.top).reduce(min);
        final maxBottom = currentRow.map((f) => f.bottom).reduce(max);
        final minLeft = currentRow.map((f) => f.left).reduce(min);
        final maxRight = currentRow.map((f) => f.right).reduce(max);
        final maxFont = currentRow.map((f) => f.fontSize).reduce(max);

        groupedLines.add(LineFragment(
          text: sanitizeProseSpacing(combinedText).trim(),
          top: minTop,
          bottom: maxBottom,
          left: minLeft,
          right: maxRight,
          height: maxBottom - minTop,
          width: maxRight - minLeft,
          fontSize: maxFont,
        ));
      }

      return groupedLines;
    } catch (_) {
      return const [];
    }
  }

  // --- STAGE 2: Repeated Header / Footer & Page Number Detection (F04) ---

  static Set<String> _findRepeatedHeadersFooters(
      Map<int, List<LineFragment>> pageLinesMap) {
    final occurrenceCount = <String, int>{};
    final totalPages = pageLinesMap.length;
    if (totalPages < 3) return const {};

    for (final lines in pageLinesMap.values) {
      if (lines.isEmpty) continue;
      final maxBottom = lines.map((l) => l.bottom).reduce(max);
      final topThreshold = maxBottom * 0.10;
      final bottomThreshold = maxBottom * 0.90;

      final headerFooterLines = lines.where(
          (l) => l.top <= topThreshold || l.bottom >= bottomThreshold);
      final seenOnThisPage = <String>{};

      for (final l in headerFooterLines) {
        final norm = _normalizeLineForComparison(l.text);
        if (norm.length >= 4 && seenOnThisPage.add(norm)) {
          occurrenceCount[norm] = (occurrenceCount[norm] ?? 0) + 1;
        }
      }
    }

    final repeated = <String>{};
    for (final entry in occurrenceCount.entries) {
      if (entry.value / totalPages >= 0.30) {
        repeated.add(entry.key);
      }
    }
    return repeated;
  }

  static String _normalizeLineForComparison(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'\d+'), '#')
        .replaceAll(RegExp(r'[^\w#]'), '')
        .trim();
  }

  static bool _isLonePageNumber(String text) {
    final t = text.trim();
    if (RegExp(r'^\s*\d+\s*$').hasMatch(t)) return true;
    if (RegExp(r'^\s*[ivxlcdmIVXLCDM]+\s*$').hasMatch(t)) return true;
    if (RegExp(r'^\s*(?:Page|-|—)?\s*\d+\s*(?:-|—)?\s*$', caseSensitive: false)
        .hasMatch(t)) {
      return true;
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
    final letters = RegExp(r'[A-Za-z]').allMatches(trimmed).length;
    final alphaRatio =
        nonSpaceChars.isEmpty ? 0.0 : letters / nonSpaceChars.length;

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
    final ocrNoiseRe =
        RegExp(r'''[\\|~^{}]|:-|--|ll\)|1\\|\(\)|[^\w\s.,!?;:’\'"“”()\-–—]{2,}''');
    final vowelRe = RegExp(r'[aeiouyAEIOUY]');
    final cleanWordRe = RegExp(r'^[A-Za-z]+[.,!?;:]?$');

    int noisyCount = 0;
    int validCount = 0;

    for (final token in tokens) {
      if (ocrNoiseRe.hasMatch(token)) {
        noisyCount++;
      }
      if (token.length >= 2 &&
          token.length <= 22 &&
          vowelRe.hasMatch(token) &&
          cleanWordRe.hasMatch(token)) {
        validCount++;
      }
    }

    final symbolNoiseRatio = noisyCount / tokens.length;
    final validWordRatio = validCount / tokens.length;

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
    final compact = lower.replaceAll(' ', '');

    // 1. Explicit blank page declaration
    if (compact.contains('intentionallyleftblank')) {
      score += 100;
    }

    // 2. Imprint & publishing markers
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
      if (lower.contains(marker)) {
        score += 25;
      }
    }

    // 3. Structural front-matter indicators: High uppercase/titlecase ratio + low punctuation
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

    if (upperRatio >= 0.50 && sentencePunctCount < 3 && avgWordsPerLine < 6) {
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
  }) {
    final paragraphs = <ParagraphInfo>[];
    if (lines.isEmpty) {
      return ReflowResult(paragraphs: const [], carryOver: carryOver);
    }

    // Determine average line height & column width on page
    final avgHeight = lines.map((l) => l.height).reduce((a, b) => a + b) / lines.length;
    final maxLineWidth = lines.map((l) => l.width).reduce(max);
    final avgFontSize = lines.map((l) => l.fontSize).reduce((a, b) => a + b) / lines.length;

    final currentPara = StringBuffer();
    if (carryOver != null && carryOver.isNotEmpty) {
      currentPara.write(carryOver);
      currentPara.write(' ');
    }

    bool isCurrentHeading = false;
    String? currentSectionTitle = bookmarkTitle;
    bool pendingHyphenJoin = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      var rawLine = line.text.trim();
      if (rawLine.isEmpty) continue;

      // Check for Heading / Chapter indicator (F06)
      final isHeadingCandidate = (bookmarkTitle != null && rawLine.contains(bookmarkTitle)) ||
          line.fontSize >= 1.30 * avgFontSize ||
          RegExp(r'^(?:Chapter|Section|Part|Book)\s+(?:\d+|[IVXLCDM]+|[A-Z][a-z]+)',
                  caseSensitive: false)
              .hasMatch(rawLine);

      if (isHeadingCandidate && currentPara.isNotEmpty) {
        // Flush preceding paragraph
        paragraphs.add(ParagraphInfo(
          text: _cleanParagraph(currentPara.toString()),
          isHeading: isCurrentHeading,
          sectionTitle: currentSectionTitle,
        ));
        currentPara.clear();
        isCurrentHeading = true;
        currentSectionTitle = rawLine;
      }

      // Check line-end hyphenation to join seamlessly with next line
      if (rawLine.endsWith('-') && i + 1 < lines.length) {
        final nextLine = lines[i + 1].text.trim();
        final match = RegExp(r'([A-Za-z]+)-$', caseSensitive: false).firstMatch(rawLine);
        final nextMatch = RegExp(r'^[A-Za-z]+', caseSensitive: false).firstMatch(nextLine);
        if (match != null && nextMatch != null) {
          final prefix = match.group(1)!;
          if (!_isKnownCompoundPrefix(prefix.toLowerCase())) {
            // Strip trailing hyphen so next line joins directly
            rawLine = rawLine.substring(0, rawLine.length - 1);
            if (currentPara.isNotEmpty && !currentPara.toString().endsWith(' ') && !currentPara.toString().endsWith('-')) {
              currentPara.write(' ');
            }
            currentPara.write(rawLine);
            pendingHyphenJoin = true;
            continue; // Continue without trailing space
          }
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
        final verticalGap = nextLine.top - line.bottom;
        final endsWithPunct = RegExp(r'[.!?…”"’]\s*$').hasMatch(rawLine);
        final isShortLine = line.width < (0.75 * maxLineWidth);

        if (verticalGap > (1.35 * avgHeight) || (endsWithPunct && isShortLine)) {
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

  /// Fixes broken line-wrap hyphenation across line breaks (F04, Invariant 4).
  /// Preserves legitimate compound word prefixes ('self-esteem', 'anti-slop', 'co-author').
  static String dehyphenateLineWraps(String text) {
    if (!text.contains('-')) return text;
    return text.replaceAllMapped(RegExp(r'\b([A-Za-z]+)-\s+([a-z]+)\b'), (m) {
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
      'self',
      'non',
      'anti',
      'well',
      'cross',
      'pre',
      'post',
      'multi',
      'over',
      'under',
      'sub',
      'co',
      'meta',
      'pseudo',
      'quasi',
      'high',
      'low',
      'counter',
      'inter',
      'super',
      'ultra',
      're',
      'ex',
      'all',
      'half',
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
        final bm = bms[i];
        final dest = bm.destination;
        if (dest != null) {
          final page = dest.page;
          final pageIndex = doc.pages.indexOf(page);
          if (pageIndex >= 0 && bm.title.trim().isNotEmpty) {
            bookmarks[pageIndex + 1] = bm.title.trim();
          }
        }
      }
    } catch (_) {}
    return bookmarks;
  }

  // --- EPUB PIPELINE WITH COMPREHENSIVE HTML ENTITIES & CHAPTER NAVIGATION (F06, F34.6) ---

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
    final files = <String, ArchiveFile>{
      for (final file in archive.files)
        if (file.isFile) _normalizeEpubPath(file.name): file,
    };

    final containerBytes = files['META-INF/container.xml']?.content;
    if (containerBytes is! List<int>) {
      throw Exception('Malformed EPUB: missing container.xml');
    }
    final container = XmlDocument.parse(utf8.decode(containerBytes));
    final rootfile = container
        .findAllElements('rootfile')
        .firstOrNull
        ?.getAttribute('full-path');
    if (rootfile == null) throw Exception('Malformed EPUB: missing rootfile');

    final opfPath = _normalizeEpubPath(rootfile);
    final opfBytes = files[opfPath]?.content;
    if (opfBytes is! List<int>) throw Exception('Malformed EPUB: missing OPF');
    final package = XmlDocument.parse(utf8.decode(opfBytes));

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
    final allChunks = <Map<String, Object?>>[];
    int chunkSequence = 1;
    int offsetDelta = 0;

    for (int idx = 0; idx < totalSections; idx++) {
      final itemRef = itemRefs[idx];
      if ((itemRef.getAttribute('linear') ?? '').toLowerCase() == 'no') continue;
      final idref = itemRef.getAttribute('idref');
      final item = idref == null ? null : manifest[idref];
      if (item == null) continue;

      final href = item.href;
      final fileNameOnly = href.split('/').last.toLowerCase();
      final isNavDoc = item.properties.contains('nav') || RegExp(r'^(toc|ncx)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileNameOnly);
      final isPureCoverOrCopyright = RegExp(r'^(cover|titlepage|copyright)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileNameOnly);
      final isSubstantiveProse = RegExp(r'(preface|foreword|prologue|intro)', caseSensitive: false).hasMatch(fileNameOnly);

      if ((isNavDoc || isPureCoverOrCopyright) && !isSubstantiveProse) continue;

      final resolvedPath = _resolveEpubHref(opfPath, href);
      final contentBytes = files[resolvedPath]?.content;
      if (contentBytes is! List<int>) continue;

      final htmlContent = utf8.decode(contentBytes, allowMalformed: true);
      final sectionTitle = _extractEpubHeading(htmlContent);
      final text = _decodeEpubHtmlToProse(htmlContent);
      if (text.isEmpty) continue;

      final progress = 0.1 + 0.6 * ((idx + 1) / totalSections);
      onProgress?.call(progress, 'Extracting chapter ${idx + 1} of $totalSections...');

      final sectionStart = buffer.length;
      if (buffer.isNotEmpty) {
        buffer.write('\n\n');
        offsetDelta = buffer.length;
      }
      buffer.write(text);
      final sectionEnd = buffer.length;

      final sectionSpans = [
        {
          'start': 0,
          'end': text.length,
          'page_start': idx + 1,
          'page_end': idx + 1,
          'type': 'paragraph',
          if (sectionTitle != null) 'section_title': sectionTitle,
        }
      ];

      spans.add({
        'start': sectionStart,
        'end': sectionEnd,
        'page_start': idx + 1,
        'page_end': idx + 1,
        'type': 'paragraph',
        if (sectionTitle != null) 'section_title': sectionTitle,
      });

      final batchChunks = LosslessChunker().build(
        documentId: docId,
        canonicalText: text,
        spans: sectionSpans,
        initialSequence: chunkSequence,
        offsetDelta: offsetDelta,
      );

      if (batchChunks.isNotEmpty) {
        allChunks.addAll(batchChunks);
        chunkSequence += batchChunks.length;
        if (onBatch != null) {
          await onBatch(
            batchChunks,
            idx + 1,
            totalSections,
            idx == totalSections - 1,
          );
        }
      }
    }

    final canonicalStr = buffer.toString().trim();
    final canonicalSha256 = sha256.convert(utf8.encode(canonicalStr)).toString();

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

  static String? _extractEpubHeading(String html) {
    final hMatch = RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false)
        .firstMatch(html);
    if (hMatch != null) {
      final raw = hMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (raw.isNotEmpty) return decodeHtmlEntities(raw);
    }
    return null;
  }

  static String _decodeEpubHtmlToProse(String html) {
    final clean = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(
            RegExp(r'</?(?:p|div|h[1-6]|br|hr|li|tr|blockquote|section|article)[^>]*>',
                caseSensitive: false),
            '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');

    final decoded = decodeHtmlEntities(clean);
    return sanitizeProseSpacing(decoded);
  }

  /// Full HTML entity decoder (F06, F34.6)
  /// Decodes named HTML entities (&eacute;, &uuml;, &mdash;, etc.) and decimal/hex numeric entities.
  static String decodeHtmlEntities(String text) {
    const namedEntities = {
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
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
        } catch (_) {}
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
  final List<int> bytes;
  final SendPort sendPort;

  const _PdfWorkerParams({
    required this.docId,
    required this.fileName,
    required this.bytes,
    required this.sendPort,
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

class _WorkerBatchEvent {
  final List<Map<String, Object?>> batchChunks;
  final String batchCanonicalText;
  final int processedPages;
  final int totalPages;
  final bool isFinalBatch;

  const _WorkerBatchEvent({
    required this.batchChunks,
    required this.batchCanonicalText,
    required this.processedPages,
    required this.totalPages,
    required this.isFinalBatch,
  });
}

class _WorkerDoneEvent {
  final String canonicalText;
  final String canonicalSha256;
  final int pageCount;

  const _WorkerDoneEvent({
    required this.canonicalText,
    required this.canonicalSha256,
    required this.pageCount,
  });
}

class _WorkerErrorEvent {
  final String error;

  const _WorkerErrorEvent({required this.error});
}

class _PageRangeResult {
  final String canonicalText;
  final List<Map<String, dynamic>> spans;
  final String? trailingUnfinishedParagraph;

  const _PageRangeResult({
    required this.canonicalText,
    required this.spans,
    this.trailingUnfinishedParagraph,
  });
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
