import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/services/ingestion_job_coordinator.dart';
import 'package:athena/services/binary_book_cache.dart';
import 'package:athena/models/document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Stage 1 Master Verification Suite', () {
    late LocalDatabase db;
    final testDocId = 'doc_test_stage1_streaming_resume';

    setUp(() async {
      db = LocalDatabase.instance;
      await db.deleteDocument(testDocId);
    });

    tearDown(() async {
      await db.deleteDocument(testDocId);
    });

    test('1. Checkpoint Resume: Interrupted at Page 32 resumes at Page 33 without wipe and matches canonical SHA-256', () async {
      // Create test document in processing state
      await db.insertDocument({
        'id': testDocId,
        'filename': 'stage1_sample.pdf',
        'title': 'Stage 1 Sample',
        'status': 'processing',
        'stage': 'extracting',
        'percent': 10,
        'page_count': 64,
        'processed_page': 0,
        'file_path': 'local://stage1_sample.pdf',
      });

      // Window 1: Pages 1..16
      final window1Text = 'Chapter 1: The Foundation of Streaming.\n'
          'This is the first sentence of our 64-page document test. '
          'We test incremental chunking across multiple windows without keeping entire books in RAM.\n\n';
      final chunks1 = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: window1Text,
        spans: [
          {'start': 0, 'end': window1Text.length, 'page_start': 1, 'page_end': 16, 'type': 'paragraph'}
        ],
        offsetDelta: 0,
        initialSequence: 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks1,
        documentId: testDocId,
        checkpointPage: 16,
        chunkSequence: chunks1.length,
        charOffset: window1Text.length,
        carryOverText: '',
        profileJson: '{"bodyFontSize":12.0}',
        isFinalBatch: false,
      );

      // Window 2: Pages 17..32
      final window2Text = 'Chapter 2: Resumability and Invariants.\n'
          'This window continues smoothly from page 17 up to page 32. '
          'When an interruption or simulated crash occurs here, all committed chunks remain intact.\n\n';
      final chunks2 = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: window2Text,
        spans: [
          {'start': 0, 'end': window2Text.length, 'page_start': 17, 'page_end': 32, 'type': 'paragraph'}
        ],
        offsetDelta: window1Text.length,
        initialSequence: chunks1.length + 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks2,
        documentId: testDocId,
        checkpointPage: 32,
        chunkSequence: chunks1.length + chunks2.length,
        charOffset: window1Text.length + window2Text.length,
        carryOverText: '',
        profileJson: '{"bodyFontSize":12.0}',
        isFinalBatch: false,
      );

      // Simulate interruption: Coordinator recovery marks orphaned job as paused / partially_readable
      await db.updateDocumentProgress(
        testDocId,
        status: 'partially_readable',
        stage: 'paused',
        processedPage: 32,
        percent: 50,
      );

      // Verify checkpoint state after interruption
      final pausedDoc = await db.getDocument(testDocId);
      expect(pausedDoc, isNotNull);
      expect(pausedDoc!['status'], equals('partially_readable'));
      expect(pausedDoc['last_checkpoint_page'], equals(32));
      expect(pausedDoc['last_chunk_sequence'], equals(chunks1.length + chunks2.length));

      final docModel = Document.fromJson(pausedDoc);
      expect(docModel.isPartiallyReadable, isTrue);
      expect(docModel.isReadable, isTrue);

      // Uncommitted tail chunks simulation (e.g. partial crash in window 3)
      final simulatedTailText = 'Simulated uncommitted crash tail text...\n';
      final simulatedUncommittedTail = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: simulatedTailText,
        spans: [
          {'start': 0, 'end': simulatedTailText.length, 'page_start': 33, 'page_end': 33, 'type': 'paragraph'}
        ],
        offsetDelta: window1Text.length + window2Text.length,
        initialSequence: chunks1.length + chunks2.length + 1,
      );
      await db.insertChunksBatch(simulatedUncommittedTail);

      final countBeforePrune = (await db.getChunks(testDocId)).length;
      expect(countBeforePrune, equals(chunks1.length + chunks2.length + simulatedUncommittedTail.length));

      // Resume from checkpoint (Page 33): prune tail beyond last committed sequence
      final lastCommittedSeq = pausedDoc['last_chunk_sequence'] as int;
      await db.pruneUncommittedTailChunks(testDocId, lastCommittedSeq);

      final countAfterPrune = (await db.getChunks(testDocId)).length;
      expect(countAfterPrune, equals(chunks1.length + chunks2.length));

      // Window 3: Pages 33..48 (Resumed)
      final window3Text = 'Chapter 3: Resuming from Page 33.\n'
          'The worker resumed cleanly at last_checkpoint_page + 1 without wiping previous chunks. '
          'Byte continuity is preserved exactly.\n\n';
      final chunks3 = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: window3Text,
        spans: [
          {'start': 0, 'end': window3Text.length, 'page_start': 33, 'page_end': 48, 'type': 'paragraph'}
        ],
        offsetDelta: window1Text.length + window2Text.length,
        initialSequence: lastCommittedSeq + 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks3,
        documentId: testDocId,
        checkpointPage: 48,
        chunkSequence: lastCommittedSeq + chunks3.length,
        charOffset: window1Text.length + window2Text.length + window3Text.length,
        carryOverText: '',
        profileJson: '{"bodyFontSize":12.0}',
        isFinalBatch: false,
      );

      // Window 4: Pages 49..64 (Final Window)
      final window4Text = 'Chapter 4: Completion.\n'
          'Final 16 pages finish the 64-page book. All four windows join with zero byte corruption.\n';
      final chunks4 = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: window4Text,
        spans: [
          {'start': 0, 'end': window4Text.length, 'page_start': 49, 'page_end': 64, 'type': 'paragraph'}
        ],
        offsetDelta: window1Text.length + window2Text.length + window3Text.length,
        initialSequence: lastCommittedSeq + chunks3.length + 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks4,
        documentId: testDocId,
        checkpointPage: 64,
        chunkSequence: lastCommittedSeq + chunks3.length + chunks4.length,
        charOffset: window1Text.length + window2Text.length + window3Text.length + window4Text.length,
        carryOverText: '',
        profileJson: '{"bodyFontSize":12.0}',
        isFinalBatch: true,
      );

      // Verify continuous reconstruction
      final allChunks = await db.getChunks(testDocId);
      final reconstructed = allChunks.map((c) => c['raw_text'] as String).join();
      final expectedFull = window1Text + window2Text + window3Text + window4Text;
      expect(reconstructed, equals(expectedFull));

      final computedSha = await db.computeDocumentCanonicalSha256(testDocId);
      final expectedSha = sha256.convert(utf8.encode(expectedFull)).toString();
      expect(computedSha, equals(expectedSha));

      // Mark ready
      final stats = await db.computeDocumentStats(testDocId);
      await db.updateDocumentProgress(
        testDocId,
        status: 'ready',
        stage: 'done',
        percent: 100,
        processedPage: 64,
        pageCount: 64,
        totalWords: stats.totalWords,
        totalCharacters: stats.totalCharacters,
        canonicalSha256: computedSha,
        integrityVerified: 1,
      );

      final finalDoc = await db.getDocument(testDocId);
      expect(finalDoc!['status'], equals('ready'));
      expect(finalDoc['original_checksum'], equals(expectedSha));
      expect(finalDoc['last_checkpoint_page'], equals(64));
    });

    test('2. Re-importing same file UID does not delete existing chunks or cascade delete (F-B4)', () async {
      // Insert initial ready document with chunks
      await db.insertDocument({
        'id': testDocId,
        'filename': 'sample.pdf',
        'title': 'Original Sample',
        'status': 'ready',
        'percent': 100,
        'page_count': 16,
        'file_path': 'local://sample.pdf',
      });

      final initialText = 'Some original text for chunking...\n';
      final initialChunks = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: initialText,
        spans: [
          {'start': 0, 'end': initialText.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}
        ],
      );
      await db.insertChunksBatch(initialChunks);

      final chunksCount1 = (await db.getChunks(testDocId)).length;
      expect(chunksCount1, greaterThan(0));

      // Re-inserting with the same docId must NOT use ConflictAlgorithm.replace to delete cascade
      await db.insertDocument({
        'id': testDocId,
        'filename': 'sample.pdf',
        'title': 'Original Sample Reimported',
        'status': 'processing',
        'file_path': 'local://sample.pdf',
      });

      final chunksCount2 = (await db.getChunks(testDocId)).length;
      expect(chunksCount2, equals(chunksCount1),
          reason: 'Re-importing must not delete or cascade drop existing chunks (F-B4)');
    });

    test('3. getDocument() and listDocuments() never read canonical_text blob (CursorWindow safety)', () async {
      await db.insertDocument({
        'id': testDocId,
        'filename': 'cursor_window_test.pdf',
        'title': 'Cursor Window Test',
        'status': 'ready',
        'percent': 100,
        'canonical_text': 'Heavy blob text that must not be selected into RAM',
      });

      final doc = await db.getDocument(testDocId);
      expect(doc, isNotNull);
      expect(doc!.containsKey('canonical_text'), isFalse,
          reason: 'canonical_text must be omitted from getDocument() to eliminate 2MB CursorWindow crashes');
      expect(doc.containsKey('spans_json'), isFalse,
          reason: 'spans_json must be omitted from getDocument()');

      final docs = await db.listDocuments();
      final matching = docs.firstWhere((d) => d['id'] == testDocId);
      expect(matching.containsKey('canonical_text'), isFalse);
      expect(matching.containsKey('spans_json'), isFalse);
    });

    test('4. BinaryBookTape null raw_text bug fix (GAP-01): raw_text is populated before buildCards', () async {
      await db.insertDocument({
        'id': testDocId,
        'filename': 'gap01_sample.pdf',
        'title': 'GAP01 Sample',
        'status': 'ready',
        'percent': 100,
        'file_path': 'local://gap01_sample.pdf',
      });

      final sampleText = 'Athena cognitive reading architecture eliminates distraction. '
          'Verified marginalia cards connect to exact quotes without distortion.\n';
      final chunks = LosslessChunker().build(
        documentId: testDocId,
        canonicalText: sampleText,
        spans: [
          {'start': 0, 'end': sampleText.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}
        ],
      );
      await db.insertChunksBatch(chunks);

      // Create BinaryBookTape
      final tapeBytes = BinaryBookTape.encode(
        chunks: chunks.map((c) => {
          ...c,
          'page_number': 1,
        }).toList(),
      );

      final tape = BinaryBookTape.fromBytes(tapeBytes);
      expect(tape.chunkCount, equals(chunks.length));

      // Test that getReaderData logic populates raw_text for every chunk
      final readerData = await db.getReaderData(testDocId);
      final readerChunks = (readerData['chunks'] as List).cast<Map<String, dynamic>>();

      for (final chunk in readerChunks) {
        expect(chunk['raw_text'], isNotNull);
        expect((chunk['raw_text'] as String).isNotEmpty, isTrue);
      }
    });

    test('5. IngestionJobCoordinator startup recovery marks orphaned processing jobs as paused', () async {
      await db.insertDocument({
        'id': testDocId,
        'filename': 'interrupted_job.pdf',
        'title': 'Interrupted Job',
        'status': 'processing',
        'stage': 'extracting',
        'percent': 25,
        'last_checkpoint_page': 16,
      });

      await IngestionJobCoordinator.instance.recoverStartupJobs();

      final recovered = await db.getDocument(testDocId);
      expect(recovered, isNotNull);
      expect(recovered!['status'], equals('paused'));
      expect(recovered['stage'], equals('paused'));
      expect(recovered['stage_label'], contains('Paused'));
      expect(recovered['last_checkpoint_page'], equals(16));
    });
  });
}
