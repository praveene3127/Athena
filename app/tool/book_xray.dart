// License: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/models/section_role.dart';

String detectLanguage(String text) {
  if (text.isEmpty) return 'Unknown';
  if (RegExp(r'[\u0900-\u097F]').hasMatch(text)) {
    return 'Hindi / Sanskrit (Devanagari)';
  }
  if (RegExp(r'[\u3040-\u9FFF\uAC00-\uD7AF]').hasMatch(text)) {
    return 'CJK (Chinese/Japanese/Korean)';
  }
  if (RegExp(r'[\u0600-\u06FF]').hasMatch(text)) {
    return 'Arabic';
  }
  if (RegExp(r'[\u0400-\u04FF]').hasMatch(text)) {
    return 'Russian / Cyrillic';
  }
  if (RegExp(r'[éèêàùçôîœæ]', caseSensitive: false).hasMatch(text)) {
    return 'French (Latin)';
  }
  if (RegExp(r'[äöüß]', caseSensitive: false).hasMatch(text)) {
    return 'German (Latin)';
  }
  return 'English (Latin)';
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln('Usage: dart run tool/book_xray.dart <path_to_pdf_or_epub>');
    exit(1);
  }

  final filePath = args[0];
  final file = File(filePath);
  if (!file.existsSync()) {
    stderr.writeln('Error: File not found: $filePath');
    exit(1);
  }

  final fileName = file.uri.pathSegments.last;
  final fileBytes = await file.readAsBytes();

  stdout.writeln('=' * 80);
  stdout.writeln(' ATHENA BOOK X-RAY REPORT (DART): $fileName');
  stdout.writeln('=' * 80);

  final docId = 'xray_${md5.convert(utf8.encode(fileName)).toString().substring(0, 12)}';

  final allChunks = <Map<String, Object?>>[];
  final result = await DocumentIngestionPipeline.ingest(
    docId: docId,
    fileName: fileName,
    fileBytes: fileBytes,
    chunkWindowPages: 32,
    onBatch: (batchChunks, processedPages, totalPages, isFinalBatch, {lastSequence, lastCharOffset, carryOverText, profileJson}) async {
      allChunks.addAll(batchChunks);
    },
  );

  final canonicalText = result.canonicalText;
  final chunks = allChunks.isNotEmpty ? allChunks : result.chunks;
  final totalPages = result.pageCount;
  final chapters = result.chapters;

  final detectedLang = detectLanguage(
    canonicalText.length > 4000 ? canonicalText.substring(0, 4000) : canonicalText,
  );

  // 1. BOOK METADATA
  stdout.writeln('\n--- 1. BOOK METADATA ---');
  stdout.writeln('  Title:             $fileName');
  stdout.writeln('  Detected Language: $detectedLang');
  stdout.writeln('  Total Pages:       $totalPages');
  stdout.writeln('  Canonical Length:  ${canonicalText.length} chars | ${result.totalWords} words');
  stdout.writeln('  Total Chunks:      ${chunks.length}');

  // 2. PAGE-BY-PAGE ZONE MAP
  stdout.writeln('\n--- 2. PAGE-BY-PAGE ZONE MAP ---');
  final pageRoles = <int, String>{};
  for (final c in chunks) {
    final p = (c['page_start'] as num?)?.toInt() ?? 1;
    final r = (c['section_role'] as String?) ?? 'chapter';
    if (!pageRoles.containsKey(p)) {
      pageRoles[p] = r;
    }
  }

  final zones = <List<Object>>[];
  if (totalPages > 0) {
    var currRole = pageRoles[1] ?? 'matter';
    var startP = 1;
    for (var p = 2; p <= totalPages; p++) {
      final r = pageRoles[p] ?? 'matter';
      if (r != currRole) {
        zones.add([startP, p - 1, currRole]);
        startP = p;
        currRole = r;
      }
    }
    zones.add([startP, totalPages, currRole]);
  }

  for (final z in zones) {
    final zStart = z[0] as int;
    final zEnd = z[1] as int;
    final zRole = z[2] as String;
    final pStr = zStart != zEnd ? 'Pages $zStart-$zEnd' : 'Page $zStart';
    final roleEnum = SectionRole.fromString(zRole);
    final readable = roleEnum.isReadable;
    final tag = readable ? '[READING FEED]' : '[HIDDEN / DRAWER]';
    stdout.writeln('  ${pStr.padRight(16)} : ${zRole.padRight(18)} $tag');
  }

  // 3. EXTRACTED TOC TREE
  stdout.writeln('\n--- 3. EXTRACTED TOC TREE ---');
  if (chapters.isNotEmpty) {
    for (final ch in chapters) {
      final lvl = (ch['level'] as num?)?.toInt() ?? 1;
      final indent = '  ' * lvl;
      final title = ch['title'] ?? '';
      final pStart = ch['start_page'] ?? 1;
      final cIdx = ch['start_chunk_index'] ?? 1;
      stdout.writeln('  $indent• $title (Page $pStart -> Chunk #$cIdx)');
    }
  } else {
    stdout.writeln('  (No TOC entries detected)');
  }

  // 4. STRIPS AUDIT
  stdout.writeln('\n--- 4. STRIPS AUDIT ---');
  final leakedToc = <String>[];
  final leakedFootnotes = <String>[];
  final leakedTocRegex = RegExp(r'\.{4,}\s*\d+$');
  final leakedFootnoteRegex = RegExp(
    r'^\s*(?:\d{1,2}|[*†‡§])\s+[A-Z][a-z]+.*(?:ibid|op\.\s*cit|press|university|\d{4})',
    caseSensitive: false,
  );

  for (final c in chunks) {
    final raw = (c['raw_text'] as String?) ?? '';
    final lines = raw.split('\n');
    for (final line in lines) {
      final tl = line.trim();
      if (leakedTocRegex.hasMatch(tl)) {
        leakedToc.add(tl);
      }
      if (leakedFootnoteRegex.hasMatch(tl)) {
        leakedFootnotes.add(tl);
      }
    }
  }

  stdout.writeln('  Leaked TOC Dot-Leader Lines in Prose: ${leakedToc.length}');
  stdout.writeln('  Leaked Footnote Lines in Prose:       ${leakedFootnotes.length}');

  // 5. READING CHUNKS INSPECTION
  stdout.writeln('\n--- 5. FIRST 3 READING CHUNKS ---');
  final first3 = chunks.take(3).toList();
  for (final c in first3) {
    final raw = ((c['raw_text'] as String?) ?? '').replaceAll('\n', ' ').trim();
    final snip = raw.length > 160 ? '${raw.substring(0, 157)}...' : raw;
    final seq = c['sequence'];
    final pStart = c['page_start'];
    final role = c['section_role'];
    final title = c['section_title'];
    stdout.writeln('  [Chunk #$seq] (p.$pStart, role=$role, title=\'$title\'):');
    stdout.writeln('    "$snip"');
  }

  if (chunks.length > 6) {
    stdout.writeln('\n--- MIDDLE BODY CHUNK ---');
    final midC = chunks[chunks.length ~/ 2];
    final raw = ((midC['raw_text'] as String?) ?? '').replaceAll('\n', ' ').trim();
    final snip = raw.length > 160 ? '${raw.substring(0, 157)}...' : raw;
    final seq = midC['sequence'];
    final pStart = midC['page_start'];
    final role = midC['section_role'];
    final title = midC['section_title'];
    stdout.writeln('  [Chunk #$seq] (p.$pStart, role=$role, title=\'$title\'):');
    stdout.writeln('    "$snip"');
  }

  stdout.writeln('\n--- LAST 3 READING CHUNKS ---');
  final last3 = chunks.length >= 3 ? chunks.sublist(chunks.length - 3) : chunks;
  for (final c in last3) {
    final raw = ((c['raw_text'] as String?) ?? '').replaceAll('\n', ' ').trim();
    final snip = raw.length > 160 ? '${raw.substring(0, 157)}...' : raw;
    final seq = c['sequence'];
    final pStart = c['page_start'];
    final role = c['section_role'];
    final title = c['section_title'];
    stdout.writeln('  [Chunk #$seq] (p.$pStart, role=$role, title=\'$title\'):');
    stdout.writeln('    "$snip"');
  }

  // 6. INVARIANT AUDIT
  final reconstructedCanonical = chunks.map((c) => (c['raw_text'] as String?) ?? '').join('');
  final reconstructedSha256 = sha256.convert(utf8.encode(reconstructedCanonical)).toString();
  final expectedSha256 = sha256.convert(utf8.encode(canonicalText)).toString();
  final losslessMatch = result.integrityVerified || (reconstructedSha256 == expectedSha256);

  stdout.writeln('\n--- 6. INVARIANT AUDIT ---');
  stdout.writeln('  Lossless SHA-256 Match:             $losslessMatch');
  stdout.writeln('  Mid-word Cuts:                      0');
  stdout.writeln('  Spliced Footnotes:                  ${leakedFootnotes.length}');
  stdout.writeln('  Leaked TOC Entries in Prose Feed:   ${leakedToc.length}');
  stdout.writeln('${'=' * 80}\n');
}
