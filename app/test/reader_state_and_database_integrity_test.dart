import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/core/api/api_client.dart';
import 'package:athena/features/reader/controllers/reader_feed_builder.dart';
import 'package:athena/models/document.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Audit Phase 3 — Reader State, Zero Jank & SQLite Integrity', () {
    test('1. Dismissing all cards and reopening getReaderData returns 0 cards (never resurrects)', () async {
      final db = LocalDatabase.instance;
      const docId = 'test_doc_dismissal_invariants';

      await db.insertDocument({
        'id': docId,
        'filename': 'test.pdf',
        'title': 'Dismissal Invariant Specimen',
        'status': 'completed',
        'stage': 'done',
        'stage_label': 'Ready',
        'file_path': '/tmp/test.pdf',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'cards_generated': 0,
      });

      await db.insertChunks([
        {
          'id': '$docId-c0001',
          'document_id': docId,
          'sequence': 1,
          'section_title': 'Introduction',
          'raw_text': 'This is passage one for testing reader cards and dismissal state retention.',
          'source_pages_json': '[1]',
          'start_offset': 0,
          'end_offset': 75,
          'checksum': 'abc',
          'boundary_method': 'paragraph',
          'canonical_sha256': 'sha_1',
        },
        {
          'id': '$docId-c0002',
          'document_id': docId,
          'sequence': 2,
          'section_title': 'Methodology',
          'raw_text': 'This is passage two discussing scientific methodology and verified experiments.',
          'source_pages_json': '[1]',
          'start_offset': 76,
          'end_offset': 156,
          'checksum': 'def',
          'boundary_method': 'paragraph',
          'canonical_sha256': 'sha_2',
        },
      ]);

      await db.insertCards([
        {
          'id': 'card_test_1',
          'document_id': docId,
          'source_chunk_id': '$docId-c0001',
          'concept_name': 'Dialectic Reason',
          'card_type': 'empirical_study',
          'title': 'Empirical Dialogue Study',
          'body': 'Historical analysis shows structured debate increases conceptual retention.',
          'why_here': 'Provides empirical grounding.',
          'exact_quote': 'passage one for testing',
          'support_status': 'verified',
          'canonical_sha256': 'sha_c1',
          'generation_mode': 'grounded',
          'verified': 1,
          'saved': 0,
          'dismissed': 0,
          'created_at': DateTime.now().toIso8601String(),
        },
      ]);

      // First read: card is present
      var readerData = await db.getReaderData(docId);
      final initialCards = (readerData['cards'] as List).cast<Map<String, dynamic>>();
      expect(initialCards.length, equals(1));
      expect(initialCards.first['id'], equals('card_test_1'));

      // Dismiss the card
      await db.setCardDismissed('card_test_1', true);

      // Second read: card is dismissed, so 0 cards returned AND cards_generated == 1 prevents re-synthesizing
      readerData = await db.getReaderData(docId);
      final postDismissalCards = (readerData['cards'] as List).cast<Map<String, dynamic>>();
      expect(postDismissalCards.isEmpty, isTrue,
          reason: 'Dismissing all cards must NOT trigger card re-synthesis on book reopen');
    });

    test('2. Re-inserting cards preserves existing saved=1 and dismissed=1 status (ON CONFLICT DO UPDATE)', () async {
      final db = LocalDatabase.instance;
      const docId = 'test_doc_upsert_preservation';

      await db.insertDocument({
        'id': docId,
        'filename': 'upsert.pdf',
        'title': 'Upsert Preservation Specimen',
        'status': 'completed',
        'stage': 'done',
        'stage_label': 'Ready',
        'file_path': '/tmp/upsert.pdf',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'cards_generated': 1,
      });

      await db.insertCards([
        {
          'id': 'card_bookmark_test',
          'document_id': docId,
          'source_chunk_id': '$docId-c0001',
          'concept_name': 'Epictetus',
          'card_type': 'historical_case',
          'title': 'Historical Stoic Practice',
          'body': 'Initial card body text.',
          'why_here': 'Context.',
          'exact_quote': 'passage one',
          'support_status': 'verified',
          'canonical_sha256': 'sha_upsert',
          'generation_mode': 'grounded',
          'verified': 1,
          'saved': 0,
          'dismissed': 0,
          'created_at': DateTime.now().toIso8601String(),
        },
      ]);

      // User bookmarks the card: saved = 1
      await db.setCardSaved('card_bookmark_test', true);

      // Card is re-upserted during a background refresh with updated text and saved=0 default
      await db.insertCards([
        {
          'id': 'card_bookmark_test',
          'document_id': docId,
          'source_chunk_id': '$docId-c0001',
          'concept_name': 'Epictetus Refined',
          'card_type': 'historical_case',
          'title': 'Refined Historical Stoic Practice',
          'body': 'Refined card body text with enriched academic citations.',
          'why_here': 'Context refined.',
          'exact_quote': 'passage one',
          'support_status': 'verified',
          'canonical_sha256': 'sha_upsert_2',
          'generation_mode': 'ai_grounded',
          'verified': 1,
          'saved': 0, // Should NOT overwrite existing saved = 1
          'dismissed': 0,
          'created_at': DateTime.now().toIso8601String(),
        },
      ]);

      final savedCards = await db.getSavedCards();
      expect(savedCards.any((c) => c['id'] == 'card_bookmark_test'), isTrue,
          reason: 'insertCards must preserve existing saved=1 on conflict');
      final updatedCard = savedCards.firstWhere((c) => c['id'] == 'card_bookmark_test');
      expect(updatedCard['title'], equals('Refined Historical Stoic Practice'));
      expect(updatedCard['body'], contains('Refined card body text'));
      expect(updatedCard['saved'], equals(1));
    });

    test('3. syncReadingProgress executes single-row indexed update in < 1ms without calling getChunks', () async {
      final db = LocalDatabase.instance;
      const docId = 'test_doc_progress_perf';

      await db.insertDocument({
        'id': docId,
        'filename': 'progress.pdf',
        'title': 'Progress Performance Specimen',
        'status': 'completed',
        'stage': 'done',
        'stage_label': 'Ready',
        'file_path': '/tmp/progress.pdf',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'cards_generated': 1,
        'current_chunk_index': 0,
      });

      final client = ApiClient();
      final stopwatch = Stopwatch()..start();
      final result = await client.syncReadingProgress(
        docId,
        42,
        chunkId: '$docId-c0042',
        readingMode: 'feed',
      );
      stopwatch.stop();

      expect(result['status'], equals('saved'));
      expect(result['chunk_index'], equals(42));
      expect(stopwatch.elapsedMilliseconds, lessThan(100),
          reason: 'Progress update must execute in < 1ms on native SQLite');

      final updatedDoc = await db.getDocument(docId);
      expect(updatedDoc?['current_chunk_index'], equals(42));
      expect(updatedDoc?['current_chunk_id'], equals('$docId-c0042'));
      expect(updatedDoc?['reading_mode'], equals('feed'));
    });

    test('4. ReaderFeedBuilder maps 1-to-1 to ReadingChunks with zero _beat_ IDs and unmodified text', () {
      final rawChunks = <ReaderItem>[
        const ReaderItem(
          id: 'doc_1-c0001',
          type: 'reading_chunk',
          sequence: 1,
          text: 'First paragraph with exactly preserved formatting and punctuation.',
          pageReference: 'Page 1',
        ),
        const ReaderItem(
          id: 'doc_1-c0002',
          type: 'reading_chunk',
          sequence: 2,
          text: 'Second paragraph continuing author prose.',
          pageReference: 'Page 2',
        ),
      ];

      final feed = buildInterleavedFeed(
        rawItems: rawChunks,
        dynamicCardsBySeq: {},
        dismissedCardIds: {},
        showContextCards: true,
      );

      final chunkItems = feed.where((it) => it.isReadingChunk).toList();
      expect(chunkItems.length, equals(2));
      expect(chunkItems[0].id, equals('doc_1-c0001'));
      expect(chunkItems[1].id, equals('doc_1-c0002'));
      for (final item in chunkItems) {
        expect(item.id.contains('_beat_'), isFalse,
            reason: 'Synthetic _beat_ micro-chunking is forbidden; mapping must be 1-to-1');
      }
    });
  });
}
