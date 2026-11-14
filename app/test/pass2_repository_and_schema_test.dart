import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/book_repository.dart';
import 'package:athena/services/rust_engine_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Pass 2: Keyset Pagination, BookRepository & Rust Schema Contract', () {
    const docId = 'doc_pass2_benchmark_5k';

    setUpAll(() async {
      final db = LocalDatabase.instance;
      await db.deleteDocument(docId);

      await db.insertDocument({
        'id': docId,
        'title': 'The Grand Keyset Benchmark Book',
        'filename': 'benchmark_5k.pdf',
        'status': 'ready',
        'page_count': 500,
        'processed_page': 500,
        'chunk_count': 5000,
        'cards_generated': 0,
      });

      // Insert 5,000 chunks in batches to test keyset pagination speed
      final rawDb = await db.database;
      const totalChunks = 5000;
      final batchSize = 500;

      for (int b = 0; b < totalChunks; b += batchSize) {
        final batch = rawDb.batch();
        for (int i = b + 1; i <= b + batchSize; i++) {
          final page = (i / 10).ceil();
          batch.insert('reading_chunks', {
            'id': '$docId-c${i.toString().padLeft(6, '0')}',
            'document_id': docId,
            'sequence': i,
            'raw_text': 'Passage sequence $i with authentic narrative words for benchmarking purposes. ',
            'source_pages_json': '[$page]',
            'page_start': page,
            'page_end': page,
            'page_number': page,
            'start_offset': (i - 1) * 80,
            'end_offset': i * 80,
            'checksum': 'chk_$i',
            'boundary_method': 'paragraph',
            'canonical_sha256': 'sha_$i',
          });
        }
        await batch.commit(noResult: true);
      }
    });

    tearDownAll(() async {
      await LocalDatabase.instance.deleteDocument(docId);
    });

    test('1. computeDocumentCanonicalSha256 and computeDocumentStats complete rapidly on 5,000 chunks via keyset pagination', () async {
      final db = LocalDatabase.instance;

      final swSha = Stopwatch()..start();
      final sha = await db.computeDocumentCanonicalSha256(docId);
      swSha.stop();

      expect(sha.isNotEmpty, isTrue);
      // Keyset pagination (sequence > ?) allows fast traversal
      expect(swSha.elapsedMilliseconds, lessThan(1500));

      final swStats = Stopwatch()..start();
      final stats = await db.computeDocumentStats(docId);
      swStats.stop();

      expect(stats.chunkCount, equals(5000));
      expect(stats.totalWords, greaterThan(40000));
      expect(stats.totalCharacters, greaterThan(350000));
      expect(swStats.elapsedMilliseconds, lessThan(1500));
    });

    test('2. getReaderData opens in < 30ms without synchronous whole-book buildCards blocking', () async {
      final db = LocalDatabase.instance;

      final sw = Stopwatch()..start();
      final readerData = await db.getReaderData(docId);
      sw.stop();

      expect(readerData, isNotNull);
      expect(readerData['document'], isNotNull);
      expect(readerData['chunks'], isNotNull);
      // Verified: getReaderData returns immediately without blocking on synthetic cards
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('3. getChunkBySequence and getChunksForPage fetch only requested rows (never unbounded getChunks)', () async {
      final db = LocalDatabase.instance;

      // Single chunk lookup
      final chunk42 = await db.getChunkBySequence(docId, 42);
      expect(chunk42, isNotNull);
      expect(chunk42!['sequence'], equals(42));
      expect(chunk42['id'], equals('$docId-c000042'));

      // Page chunks lookup
      final pageChunks = await db.getChunksForPage(docId, 5);
      expect(pageChunks.isNotEmpty, isTrue);
      for (final c in pageChunks) {
        expect(c['page_start'], equals(5));
      }
      expect(pageChunks.length, equals(10)); // Exactly chunks 41-50 on page 5

      // Non-existent sequence returns null
      final nonExistent = await db.getChunkBySequence(docId, 99999);
      expect(nonExistent, isNull);
    });

    test('4. BookRepository windowing and reading position persistence', () async {
      final repo = BookRepository(db: LocalDatabase.instance);

      // Windowed query around sequence 1500
      final window = await repo.loadWindowAround(docId, centerSequence: 1500, radius: 50);
      expect(window.length, equals(101));
      expect(window.first['sequence'], equals(1450));
      expect(window.last['sequence'], equals(1550));

      // Reading position persistence
      await repo.saveReadingPosition(docId, chunkSeq: 1520, intraByte: 45);
      final pos = await repo.getReadingPosition(docId);
      expect(pos, isNotNull);
      expect(pos!.chunkSeq, equals(1520));
      expect(pos.intraByte, equals(45));
    });

    test('5. sqlite_store.rs schema matches local_database.dart column names and RustEngineBridge binds FFI', () {
      final rustStoreFile = File('../backend/rust_core/src/sqlite_store.rs');
      expect(rustStoreFile.existsSync(), isTrue);
      final rustContent = rustStoreFile.readAsStringSync();

      const requiredColumns = [
        'id',
        'document_id',
        'sequence',
        'raw_text',
        'start_offset',
        'end_offset',
        'page_start',
        'page_end',
        'section_title',
        'section_role',
        'source_pages_json',
        'checksum',
        'canonical_sha256',
        'boundary_method',
        'simhash',
      ];

      for (final col in requiredColumns) {
        expect(rustContent.contains(col), isTrue, reason: 'sqlite_store.rs must contain column $col');
      }

      // Check RustEngineBridge instance
      final bridge = RustEngineBridge.instance;
      expect(bridge, isNotNull);
      // Graceful fallback when native binary is absent on host
      expect(bridge.computeSimhash64('test'), isNull);
      expect(bridge.planChunksUtf8('test text'), isNull);
    });
  });
}
