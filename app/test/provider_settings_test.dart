import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:athena/core/api/api_client.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/lossless_chunker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test(
      'prose spacing keeps names, brands, degrees, contractions and quotes intact',
      () {
    const source = 'McDonald iPhone PhD don\'t "Hello" and "World"';
    expect(sanitizeProseSpacing(source), source);
  });

  test('EPUB extraction follows OPF spine order and excludes navigation pages',
      () {
    final archive = Archive();
    void add(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    // Deliberately scrambled ZIP order. The OPF spine is authoritative.
    add('OPS/Text/chapter2.xhtml',
        '<html><body><p>SECOND CHAPTER</p></body></html>');
    add('OPS/Text/toc.xhtml',
        '<html><body><p>TABLE OF CONTENTS SHOULD NOT APPEAR</p></body></html>');
    add('META-INF/container.xml',
        '''<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>''');
    add('OPS/content.opf', '''
      <package><manifest>
        <item id="c2" href="Text/chapter2.xhtml" media-type="application/xhtml+xml"/>
        <item id="toc" href="Text/toc.xhtml" properties="nav" media-type="application/xhtml+xml"/>
        <item id="c1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/>
        <item id="titlepage" href="Text/titlepage.xhtml" media-type="application/xhtml+xml"/>
      </manifest><spine>
        <itemref idref="c1"/><itemref idref="toc"/><itemref idref="c2"/>
        <itemref idref="titlepage" linear="no"/>
      </spine></package>''');
    add('OPS/Text/chapter1.xhtml',
        '<html><body><h1>FIRST CHAPTER</h1><p>A &mdash; &ldquo;line&rdquo;.</p></body></html>');
    add('OPS/Text/titlepage.xhtml',
        '<html><body><p>HIDDEN TITLE PAGE</p></body></html>');

    final bytes = ZipEncoder().encode(archive)!;
    final text = extractEpubText(bytes);
    expect(text.indexOf('FIRST CHAPTER'),
        lessThan(text.indexOf('SECOND CHAPTER')));
    expect(text, contains('A — “line”.'));
    expect(text, isNot(contains('TABLE OF CONTENTS')));
    expect(text, isNot(contains('HIDDEN TITLE PAGE')));
  });

  test('SQLite search safely handles punctuation and delete removes FTS rows',
      () async {
    final id = 'audit_${DateTime.now().microsecondsSinceEpoch}';
    final db = LocalDatabase.instance;
    final now = DateTime.now().toIso8601String();
    await db.insertDocument({
      'id': id,
      'filename': 'audit.pdf',
      'title': 'Audit',
      'status': 'ready',
      'stage': 'done',
      'stage_label': 'Ready',
      'percent': 100,
      'page_count': 1,
      'processed_page': 1,
      'file_path': '',
      'created_at': now,
      'updated_at': now,
    });
    await db.insertChunks([
      {
        'id': '${id}_chunk_1',
        'document_id': id,
        'sequence': 1,
        'section_title': 'Testing',
        'raw_text': 'The C++ guide includes a "quoted phrase".',
        'source_pages_json': '[1]',
        'start_offset': 0,
        'end_offset': 42,
        'checksum': 'test',
        'boundary_method': 'paragraph',
        'canonical_sha256': 'test',
      },
    ]);

    await db.saveQuote({
      'id': '${id}_quote',
      'document_id': id,
      'document_title': 'Audit',
      'chunk_id': '${id}_chunk_1',
      'page_reference': 'Page 1',
      'text': 'A "quoted phrase".',
      'note': 'Saved passage',
      'created_at': now,
    });
    expect(
        (await db.getSavedQuotes())
            .any((quote) => quote['id'] == '${id}_quote'),
        isTrue);

    expect(await db.searchChunks(id, 'C++'), isNotEmpty);
    expect(await db.searchChunks(id, '"quote'), isNotEmpty);
    final rawDb = await db.database;
    expect(
        await rawDb.rawQuery(
            'SELECT chunk_id FROM reading_chunks_fts WHERE document_id = ?',
            [id]),
        isNotEmpty);
    await db.deleteDocument(id);
    expect(
        await rawDb.rawQuery(
            'SELECT chunk_id FROM reading_chunks_fts WHERE document_id = ?',
            [id]),
        isEmpty);
    expect(
        (await db.getSavedQuotes())
            .any((quote) => quote['id'] == '${id}_quote'),
        isTrue);
  });

  test(
      'provider connection discovery performs GET /models before any completion call',
      () async {
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'data': [
          {'id': 'test-model', 'name': 'Test Model'}
        ]
      }));
      await request.response.close();
    });
    try {
      final result = await HttpOverrides.runWithHttpOverrides(
        () => ApiClient.directTestProvider(
          provider: 'custom',
          baseUrl: 'http://${server.address.address}:${server.port}/v1',
        ),
        _RealHttpOverrides(),
      );
      expect(result['ok'], isTrue);
      expect(result['models'], isNotEmpty);
      expect(requests, ['GET /v1/models']);
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

class _RealHttpOverrides extends HttpOverrides {}
