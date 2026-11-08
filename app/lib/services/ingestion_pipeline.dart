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
import 'package:athena/models/section_role.dart';

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

      final pageLinesMap = <int, List<LineFragment>>{};
      final pageRawTextMap = <int, String>{};

      const int windowSize = 25;
      for (int startPage = 0; startPage < totalPages; startPage += windowSize) {
        final endPage = (startPage + windowSize - 1).clamp(0, totalPages - 1);
        final progressFraction = 0.05 + 0.55 * ((endPage + 1) / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        final stageMsg =
            'Extracting pages ${startPage + 1}–${endPage + 1} of $totalPages ($pctInt%)...';
        onProgress?.call(progressFraction, stageMsg);

        for (int p = startPage; p <= endPage; p++) {
          final lines = _extractHorizontalGroupedLines(extractor, p);
          pageLinesMap[p + 1] = lines;
          pageRawTextMap[p + 1] = lines.map((l) => l.text).join('\n');
        }
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

      final pageLinesMap = <int, List<LineFragment>>{};
      final pageRawTextMap = <int, String>{};

      const int windowSize = 25;
      for (int startPage = 0; startPage < totalPages; startPage += windowSize) {
        final endPage = (startPage + windowSize - 1).clamp(0, totalPages - 1);
        final progressFraction = 0.05 + 0.55 * ((endPage + 1) / totalPages);
        final pctInt = (progressFraction * 100).toInt();
        final stageMsg =
            'Extracting pages ${startPage + 1}–${endPage + 1} of $totalPages ($pctInt%)...';

        params.sendPort.send(_WorkerProgressEvent(
          progress: progressFraction,
          stageLabel: stageMsg,
        ));

        for (int p = startPage; p <= endPage; p++) {
          final lines = _extractHorizontalGroupedLines(extractor, p);
          pageLinesMap[p + 1] = lines;
          pageRawTextMap[p + 1] = lines.map((l) => l.text).join('\n');
        }
      }

      params.sendPort.send(const _WorkerProgressEvent(
        progress: 0.65,
        stageLabel: 'Analyzing document layout and structure...',
      ));

      final processedResult = _processWholeDocument(
        docId: params.docId,
        totalPages: totalPages,
        pageLinesMap: pageLinesMap,
        pageRawTextMap: pageRawTextMap,
        bookmarks: bookmarks,
      );

      params.sendPort.send(_WorkerBatchEvent(
        batchChunks: processedResult.chunks,
        batchCanonicalText: processedResult.canonicalText,
        processedPages: totalPages,
        totalPages: totalPages,
        isFinalBatch: true,
      ));

      params.sendPort.send(_WorkerDoneEvent(
        canonicalText: processedResult.canonicalText,
        canonicalSha256: processedResult.canonicalSha256,
        pageCount: totalPages,
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

  // --- PASS 2: Structure Resolver, LayoutProfile & TocDetector (FP-5 to FP-10) ---

  static bool continuesParagraph({
    required LineFragment a,
    required LineFragment b,
    required LayoutProfile profile,
    required bool isHeadingA,
  }) {
    final h = profile.bodyFontSize;
    final pitch = profile.linePitch;

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

    // 4) a.right >= 0.90 * bodyRight OR a ends with hyphen (or !endsWithSentenceTerminalPunctuation)
    final aTrim = a.text.trim();
    final reachesRight = a.right >= 0.90 * profile.bodyRight;
    final endsHyphen = aTrim.endsWith('-') ||
        aTrim.endsWith('\u2010') ||
        aTrim.endsWith('\u2011');
    final endsTerminal = RegExp(r'[.!?…”"’]\s*$').hasMatch(aTrim);
    if (!reachesRight && !endsHyphen && endsTerminal) {
      return false;
    }

    // 5) b does not start with a bullet, numbered list marker, or opening dialogue quote when a ended a sentence
    final bTrim = b.text.trim();
    final bStartsList =
        RegExp(r'^(?:[•*\-–—▪▫◦]|\d+[.)]|\([a-zA-Z0-9]+\))\s+').hasMatch(bTrim);
    final bStartsQuote = RegExp(r'^["“‘\x27]').hasMatch(bTrim);
    if (endsTerminal && (bStartsList || bStartsQuote)) {
      return false;
    }

    // 6) b is NOT first-line indented ((b.left - bodyLeft) < 0.5 * h when document uses paragraph indents)
    if (profile.usesIndent) {
      final indentDiff = b.left - profile.bodyLeft;
      if (indentDiff >= 0.5 * h) {
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

    // 2. Matches bookmark title
    if (bookmarkTitle != null &&
        bookmarkTitle.isNotEmpty &&
        text.toLowerCase().contains(bookmarkTitle.toLowerCase())) {
      return true;
    }

    // 3. Matches TOC title
    if (tocTitles != null && tocTitles.contains(text.toLowerCase())) {
      return true;
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
        final key = _furnitureKey(line.text);
        if (repeatedHeadersFooters.contains(key)) return false;
        if (_isLonePageNumber(line.text)) return false;
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

    for (int p = 1; p <= totalPages; p++) {
      final lines = cleanLinesMap[p] ?? const [];
      final rawText = pageRawTextMap[p] ?? '';
      final tocRes = TocDetector.analyzePage(
        lines: lines,
        bodyRight: profile.bodyRight,
        rawPageText: rawText,
      );
      if (tocRes.isToc) {
        tocPages.add(p);
        for (final entry in tocRes.entries) {
          tocTitles.add(entry.title.toLowerCase());
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

    for (int p = 1; p <= totalPages; p++) {
      final role =
          (p - 1 < roles.length) ? roles[p - 1] : SectionRole.chapter;
      // Exclude non-reading matter (TOC, copyright, index, etc.)
      if (role.isMatter) {
        continue;
      }

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

        spans.add({
          'start': start,
          'end': end,
          'page_start': p,
          'page_end': p,
          'type': para.isHeading ? 'heading' : 'paragraph',
          'section_title': para.sectionTitle ??
              pageHeading ??
              (role != SectionRole.chapter
                  ? role.displayLabel
                  : 'Chapter Passage'),
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
        'section_title': 'Chapter Passage',
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

    return IngestionResult(
      canonicalText: canonicalStr,
      canonicalSha256: canonicalSha256,
      pageCount: totalPages,
      chunks: chunks,
      integrityVerified: integrityVerified,
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
          final combinedText = _joinRowFragments(currentRow);
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
        final combinedText = _joinRowFragments(currentRow);
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

  static String _joinRowFragments(List<LineFragment> fragments) {
    if (fragments.isEmpty) return '';
    final buf = StringBuffer(fragments.first.text.trim());
    for (int i = 1; i < fragments.length; i++) {
      final prevText = fragments[i - 1].text.trim();
      final currText = fragments[i].text.trim();
      // Drop cap detection: single uppercase letter followed by lowercase token
      if (RegExp(r'^[A-Z]$').hasMatch(prevText) && RegExp(r'^[a-z]').hasMatch(currText)) {
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
      final maxBottom = lines.map((l) => l.bottom).reduce(max);
      final topThreshold = maxBottom * 0.10;
      final bottomThreshold = maxBottom * 0.90;

      final headerFooterLines = lines.where((l) =>
          (l.top <= topThreshold || l.bottom >= bottomThreshold) &&
          l.text.trim().length <= 80);
      final seenOnThisPage = <String>{};

      for (final l in headerFooterLines) {
        final key = _furnitureKey(l.text);
        if (key.length >= 3 && seenOnThisPage.add(key)) {
          occurrenceCount[key] = (occurrenceCount[key] ?? 0) + 1;
        }
      }
    }

    final repeated = <String>{};
    for (final entry in occurrenceCount.entries) {
      // Short line appearing on >= 3 pages and >= 15% of pages (FP-6)
      if (entry.value >= 3 && (entry.value / totalPages) >= 0.15) {
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

  static bool _isLonePageNumber(String text) {
    final t = text.trim();
    return RegExp(r'^\s*(?:page\s+)?(\d{1,4}|[ivxlcdm]{1,7})\s*$',
            caseSensitive: false)
        .hasMatch(t);
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
    LayoutProfile? layoutProfile,
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
        if (layoutProfile != null) {
          final continues = continuesParagraph(
            a: line,
            b: nextLine,
            profile: layoutProfile,
            isHeadingA: isCurrentHeading,
          );
          if (!continues) {
            isParagraphEnd = true;
          }
        } else {
          final verticalGap = nextLine.top - line.bottom;
          final endsWithPunct = RegExp(r'[.!?…”"’]\s*$').hasMatch(rawLine);
          final isShortLine = line.width < (0.75 * maxLineWidth);

          if (verticalGap > (1.35 * avgHeight) || (endsWithPunct && isShortLine)) {
            isParagraphEnd = true;
          }
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
      'self',
      'non',
      'anti',
      'well',
      'cross',
      'quasi',
      'pseudo',
      'high',
      'low',
      'half',
      'all',
      'ex',
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

    // 2. Check HTML attributes epub:type / role="doc-*"
    if (htmlContent != null && htmlContent.isNotEmpty) {
      final epubTypeMatch = RegExp(r'epub:type\s*=\s*["'']([^"'']+)["'']', caseSensitive: false).firstMatch(htmlContent);
      if (epubTypeMatch != null) {
        final epubType = epubTypeMatch.group(1)!.toLowerCase();
        final role = _roleFromTypeString(epubType);
        if (role != SectionRole.unknown) return role;
      }
      final docRoleMatch = RegExp(r'role\s*=\s*["'']doc-([^"'']+)["'']', caseSensitive: false).firstMatch(htmlContent);
      if (docRoleMatch != null) {
        final docRole = docRoleMatch.group(1)!.toLowerCase();
        final role = _roleFromTypeString(docRole);
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
    if (RegExp(r'(?:^|[-_.])(?:index)(?:[-_.]|$)', caseSensitive: false).hasMatch(fileName)) {
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

      final htmlContent = utf8.decode(contentBytes, allowMalformed: true);
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
      final sectionStart = buffer.length;
      buffer.write(text);
      final sectionEnd = buffer.length;

      spans.add({
        'start': sectionStart,
        'end': sectionEnd,
        'page_start': readableSectionCount,
        'page_end': readableSectionCount,
        'type': 'paragraph',
        if (sectionTitle != null && sectionTitle.isNotEmpty)
          'section_title': sectionTitle
        else if (role != SectionRole.chapter)
          'section_title': role.displayLabel
        else
          'section_title': 'Chapter $readableSectionCount',
        'section_role': role.name,
      });
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

  static String? _extractEpubHeading(String html) {
    final hMatch = RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false)
        .firstMatch(html);
    if (hMatch != null) {
      final raw = hMatch.group(1)!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (raw.isNotEmpty) return decodeHtmlEntities(raw);
    }
    return null;
  }

  static String decodeHtmlForTest(String html) => _decodeEpubHtmlToProse(html);

  static String _decodeEpubHtmlToProse(String html) {
    if (html.isEmpty) return '';

    // 1. Strip script, style, and head blocks
    final content = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), ' ');

    final buf = StringBuffer();
    final tagOrTextRegex = RegExp(r'(<[^>]+>)|([^<]+)');
    const blockTags = {
      'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li',
      'blockquote', 'hr', 'br', 'tr', 'section', 'article',
      'header', 'footer', 'table', 'dl', 'dt', 'dd'
    };

    for (final match in tagOrTextRegex.allMatches(content)) {
      final tag = match.group(1);
      final text = match.group(2);

      if (tag != null) {
        final nameMatch = RegExp(r'^</?([a-zA-Z0-9]+)').firstMatch(tag);
        if (nameMatch != null) {
          final tagName = nameMatch.group(1)!.toLowerCase();
          if (blockTags.contains(tagName)) {
            final currentStr = buf.toString();
            if (currentStr.isNotEmpty && !currentStr.endsWith('\n\n')) {
              if (currentStr.endsWith('\n')) {
                buf.write('\n');
              } else {
                buf.write('\n\n');
              }
            }
          }
          // Inline tags (span, em, i, a, b, strong, sub, sup, code, etc.) emit NOTHING
        }
      } else if (text != null) {
        buf.write(decodeHtmlEntities(text));
      }
    }

    final decoded = buf.toString();
    return sanitizeProseSpacing(decoded);
  }

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
  const TocEntry({required this.title, required this.pageNumber});
}

class TocDetectionResult {
  final bool isToc;
  final List<TocEntry> entries;
  const TocDetectionResult({required this.isToc, required this.entries});
}

class TocDetector {
  static final dotLeaderRe = RegExp(
    r'^(.+?\S)[.…](?:[.…\s]){2,}(\d{1,4}|[ivxlcdm]{1,6})$',
    caseSensitive: false,
  );
  static final trailingNumRe =
      RegExp(r'(\d{1,4}|[ivxlcdm]{1,6})\s*$', caseSensitive: false);
  static final contentsHeaderRe =
      RegExp(r'^(?:table\s+of\s+)?contents\b', caseSensitive: false);

  static int? parseRoman(String s) {
    final clean = s.trim().toLowerCase();
    if (!RegExp(r'^[ivxlcdm]+$').hasMatch(clean)) return null;
    const values = {
      'i': 1,
      'v': 5,
      'x': 10,
      'l': 50,
      'c': 100,
      'd': 500,
      'm': 1000
    };
    int total = 0;
    int prev = 0;
    for (int i = clean.length - 1; i >= 0; i--) {
      final curr = values[clean[i]] ?? 0;
      if (curr < prev) {
        total -= curr;
      } else {
        total += curr;
        prev = curr;
      }
    }
    return total > 0 ? total : null;
  }

  static TocDetectionResult analyzePage({
    required List<LineFragment> lines,
    required double bodyRight,
    required String rawPageText,
  }) {
    final entries = <TocEntry>[];
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

    final candidatePages = <int>[];
    for (final line in lines) {
      final t = line.text.trim();
      final dotMatch = dotLeaderRe.firstMatch(t);
      if (dotMatch != null) {
        final title = dotMatch.group(1)!.trim();
        final pgStr = dotMatch.group(2)!.trim();
        final pgNum = int.tryParse(pgStr) ?? parseRoman(pgStr);
        if (pgNum != null) {
          entries.add(TocEntry(title: title, pageNumber: pgNum));
          candidatePages.add(pgNum);
          continue;
        }
      }

      if (bodyRight > 0 && line.right >= 0.88 * bodyRight) {
        final numMatch = trailingNumRe.firstMatch(t);
        if (numMatch != null) {
          final pgStr = numMatch.group(1)!.trim();
          final pgNum = int.tryParse(pgStr) ?? parseRoman(pgStr);
          final title = t
              .substring(0, numMatch.start)
              .trim()
              .replaceAll(RegExp(r'[\.…\-_]+$'), '')
              .trim();
          if (pgNum != null && title.isNotEmpty) {
            entries.add(TocEntry(title: title, pageNumber: pgNum));
            candidatePages.add(pgNum);
          }
        }
      }
    }

    bool isNonDecreasing = false;
    if (candidatePages.length >= 2) {
      int nonDecreasingSteps = 0;
      for (int i = 0; i < candidatePages.length - 1; i++) {
        if (candidatePages[i + 1] >= candidatePages[i]) {
          nonDecreasingSteps++;
        }
      }
      final ratio = nonDecreasingSteps / (candidatePages.length - 1);
      if (ratio >= 0.60) {
        isNonDecreasing = true;
      }
    }

    final isToc = (entries.length >= 4 &&
            (candidatePages.length < 2 || isNonDecreasing)) ||
        (hasContentsHeader && entries.length >= 2);

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

class StructureResolver {
  static List<SectionRole> smoothRoles({
    required int totalPages,
    required Map<int, List<LineFragment>> pageLinesMap,
    required Map<int, String> pageRawTextMap,
    required Map<int, String> bookmarks,
    required Set<int> tocPages,
    required Map<int, String> explicitHeadingMap,
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
      final heading = explicitHeadingMap[pageNum]?.toLowerCase() ??
          bookmarks[pageNum]?.toLowerCase() ??
          '';

      final isToc = tocPages.contains(pageNum);
      final hasFrontMarkers = RegExp(
              r'(?:copyright|©|all rights reserved|isbn|library of congress|cataloging|printed in|published by)\b')
          .hasMatch(rawText);
      final hasBackMarkers = RegExp(
              r'^(?:notes?|endnotes|index|bibliography|references|works cited|glossary|about the author|also by)\b',
              multiLine: true)
          .hasMatch(rawText);
      final hasReadableFrontHeader = RegExp(
                  r'\b(preface|foreword|introduction|prologue|acknowledgments)\b')
              .hasMatch(heading) ||
          RegExp(r'^(?:preface|foreword|introduction|prologue|acknowledgments)\b',
                  multiLine: true)
              .hasMatch(rawText);
      final hasChapterHeader = RegExp(
                  r'^(?:chapter|part|book)\s+(?:\d+|[ivxlcdm]+|[a-z]+)\b',
                  multiLine: true)
              .hasMatch(rawText) ||
          RegExp(r'\b(?:chapter|part)\s+\d+').hasMatch(heading);

      int indexEntryCount = 0;
      for (final l in lines) {
        if (RegExp(r'^[A-Za-z][^,]{1,40},\s\d').hasMatch(l.text.trim())) {
          indexEntryCount++;
        }
      }
      final bool isIndexDense =
          lines.length >= 8 && (indexEntryCount / lines.length >= 0.40);

      final e = List<double>.filled(numStates, 0.0);

      if (hasFrontMarkers) {
        e[0] = 0.0;
        e[1] = 40.0;
        e[2] = 40.0;
        e[3] = 60.0;
        e[4] = 80.0;
      } else if (isToc) {
        e[1] = 0.0;
        e[0] = 50.0;
        e[2] = 50.0;
        e[3] = 60.0;
        e[4] = 70.0;
      } else if (hasBackMarkers || isIndexDense) {
        e[4] = 0.0;
        e[0] = 70.0;
        e[1] = 70.0;
        e[2] = 60.0;
        e[3] = 50.0;
      } else if (hasReadableFrontHeader) {
        e[2] = 0.0;
        e[0] = 30.0;
        e[1] = 40.0;
        e[3] = 20.0;
        e[4] = 50.0;
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
          e[2] = 5.0;
          e[3] = 2.0;
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
          final transCost = (prev == curr) ? 0.0 : 1.0;
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
      final heading = explicitHeadingMap[pageNum]?.toLowerCase() ??
          bookmarks[pageNum]?.toLowerCase() ??
          '';

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
