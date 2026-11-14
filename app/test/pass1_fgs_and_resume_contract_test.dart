import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/core/errors.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/ingestion_job_coordinator.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/services/lossless_chunker.dart';

List<int> _createBlankPdf() {
  final document = PdfDocument();
  document.pages.add(); // 1 blank page without any text
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const fgChannel = MethodChannel('com.athena.reading/foreground_service');
  final methodCalls = <MethodCall>[];

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fgChannel, (MethodCall call) async {
      methodCalls.add(call);
      return true;
    });
  });

  setUp(() {
    methodCalls.clear();
  });

  group('Pass 1: Foreground Service, Resume Contract & Carry-Over Bug Tests', () {
    test('1. IngestionJobCoordinator invokes foreground service lifecycle methods matching MainActivity.kt', () async {
      final coordinator = IngestionJobCoordinator.instance;

      await coordinator.requestNotificationPermission();
      expect(
        methodCalls.any((c) => c.method == 'requestNotificationPermission'),
        isTrue,
        reason: 'Should invoke requestNotificationPermission',
      );

      // Invoke updateForegroundProgress (with percent 0 to bypass throttling)
      await coordinator.updateForegroundProgress(
        title: 'Testing Book',
        page: 5,
        total: 20,
        percent: 25,
      );

      final updateCall = methodCalls.firstWhere(
        (c) => c.method == 'updateForegroundProgress',
        orElse: () => const MethodCall('none'),
      );
      expect(updateCall.method, equals('updateForegroundProgress'));
      final args = updateCall.arguments as Map<dynamic, dynamic>;
      expect(args['title'], equals('Testing Book'));
      expect(args['page'], equals(5));
      expect(args['total'], equals(20));
      expect(args['percent'], equals(25));
    });

    test('2. Stale carry_over_text is unconditionally updated to empty string on null window', () async {
      final db = LocalDatabase.instance;
      const docId = 'doc_test_carryover_unconditional_fix';
      await db.deleteDocument(docId);

      await db.insertDocument({
        'id': docId,
        'filename': 'carryover_test.pdf',
        'title': 'CarryOver Test',
        'status': 'processing',
        'stage': 'extracting',
        'percent': 10,
        'page_count': 32,
        'processed_page': 0,
        'file_path': 'local://carryover_test.pdf',
      });

      // Window 1: with carryOverText: 'unfinished sentence...'
      final text1 = 'Window 1 content that ends with an unfinished';
      final chunks1 = LosslessChunker().build(
        documentId: docId,
        canonicalText: text1,
        spans: [
          {'start': 0, 'end': text1.length, 'page_start': 1, 'page_end': 16, 'type': 'paragraph'}
        ],
        offsetDelta: 0,
        initialSequence: 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks1,
        documentId: docId,
        checkpointPage: 16,
        chunkSequence: chunks1.length,
        charOffset: text1.length,
        carryOverText: 'unfinished',
        isFinalBatch: false,
      );

      final docAfterW1 = await db.getDocument(docId);
      expect(docAfterW1?['carry_over_text'], equals('unfinished'));

      // Window 2: ends cleanly with carryOverText: null
      final text2 = ' sentence... And then completed cleanly.';
      final chunks2 = LosslessChunker().build(
        documentId: docId,
        canonicalText: text2,
        spans: [
          {'start': 0, 'end': text2.length, 'page_start': 17, 'page_end': 32, 'type': 'paragraph'}
        ],
        offsetDelta: text1.length,
        initialSequence: chunks1.length + 1,
      );

      await db.insertChunksBatchWithCheckpoint(
        chunks2,
        documentId: docId,
        checkpointPage: 32,
        chunkSequence: chunks1.length + chunks2.length,
        charOffset: text1.length + text2.length,
        carryOverText: null, // Null should overwrite stale 'unfinished' with ''
        isFinalBatch: true,
      );

      final docAfterW2 = await db.getDocument(docId);
      // R5 Proof: carry_over_text in SQLite must be '' (not stale 'unfinished'!)
      expect(docAfterW2?['carry_over_text'], equals(''));

      await db.deleteDocument(docId);
    });

    test('3. Partially readable document with stale heartbeat recovers to paused and DocumentStatus.isDone is true', () async {
      final db = LocalDatabase.instance;
      const docId = 'doc_test_partially_readable_heartbeat_stale';
      await db.deleteDocument(docId);

      final staleTimestamp = DateTime.now().millisecondsSinceEpoch - 45000; // 45s ago (> 30s)
      await db.insertDocument({
        'id': docId,
        'filename': 'partial_doc.pdf',
        'title': 'Partial Doc',
        'status': 'partially_readable',
        'stage': 'extracting',
        'last_checkpoint_page': 32,
        'last_chunk_sequence': 12,
        'last_char_offset': 1000,
        'percent': 50,
        'page_count': 64,
        'processed_page': 32,
        'heartbeat_at': staleTimestamp,
        'file_path': 'local://partial_doc.pdf',
      });

      // Run startup recovery
      await IngestionJobCoordinator.instance.recoverStartupJobs();

      final doc = await db.getDocument(docId);
      expect(doc, isNotNull);
      expect(doc!['status'], equals('paused'));
      expect(doc['last_checkpoint_page'], equals(32));

      final rawStatus = await db.getDocumentStatus(docId);
      expect(rawStatus, isNotNull);
      final status = DocumentStatus.fromJson(rawStatus!);
      expect(status.isPaused, isTrue);
      // P0-07 / R8: isDone must be true for paused documents so polling halts and resume UI renders
      expect(status.isDone, isTrue);

      // Verify continueDocument falls back locally even if apiBaseUrl points to unreachable host
      await AppConfig.setBaseUrl('http://10.255.255.1:65432');
      final client = ApiClient();
      // Calling continueDocument will attempt server, fail with network error, and invoke local coordinator
      try {
        await client.continueDocument(docId);
      } catch (e) {
        // Document has dummy local:// file path so coordinator falls back locally and fails with FILE_NOT_FOUND
        expect(e, isA<AppError>());
        expect((e as AppError).code, equals('FILE_NOT_FOUND'));
      } finally {
        await AppConfig.setBaseUrl('');
      }

      await db.deleteDocument(docId);
    });

    test('4. Zero-chunk PDF completes with EMPTY_DOCUMENT AppError instead of hanging on events.single', () async {
      final blankBytes = _createBlankPdf();
      expect(blankBytes.isNotEmpty, isTrue);

      expect(
        () async => await DocumentIngestionPipeline.ingest(
          docId: 'doc_test_zero_chunk_hang',
          fileName: 'blank.pdf',
          fileBytes: blankBytes,
        ),
        throwsA(
          isA<AppError>().having((e) => e.code, 'code', equals('EMPTY_DOCUMENT')),
        ),
      );
    });
  });
}
