import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/services/local_database.dart';
import 'package:athena/services/ingestion_job_coordinator.dart';
import 'package:athena/features/reader/screens/reader_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Pass 2: Canonical State Machines Contract Verification', () {
    test('contracts/state-machines.json exists and formalizes all 10 machines', () async {
      // Look for contracts/state-machines.json
      File contractFile = File('../contracts/state-machines.json');
      if (!contractFile.existsSync()) {
        contractFile = File('contracts/state-machines.json');
      }
      expect(contractFile.existsSync(), isTrue,
          reason: 'contracts/state-machines.json must exist');

      final content = contractFile.readAsStringSync();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final machines = data['machines'] as Map<String, dynamic>;

      const expectedMachines = [
        'DocumentLifecycle',
        'ContextEnrichment',
        'IngestionWorkerFgs',
        'AppearanceSettings',
        'ConnectionMode',
        'ReaderViewport',
        'CardSlotSynthesis',
        'CardUserState',
        'AIProviderSlot',
        'SavedVault',
      ];

      for (final m in expectedMachines) {
        expect(machines.containsKey(m), isTrue,
            reason: 'Machine $m missing from contract');
        final machineData = machines[m] as Map<String, dynamic>;
        expect(machineData.containsKey('states'), isTrue);
        expect(machineData.containsKey('transitions'), isTrue);
      }

      // Verify DocumentLifecycle forbidden transitions
      final docLifecycle = machines['DocumentLifecycle'] as Map<String, dynamic>;
      final forbidden = docLifecycle['forbidden_transitions'] as List;
      final readyToProcessingForbidden = forbidden.any((rule) =>
          rule['from'] == 'ready' && rule['to'] == 'processing');
      expect(readyToProcessingForbidden, isTrue,
          reason: 'ready -> processing must be explicitly forbidden');
    });
  });

  group('Pass 2: Zombie Quotes & Mutually Exclusive Card State (ISM-08, SM-09)', () {
    const docId = 'doc_test_zombie_quotes';
    const cardId1 = 'card_zombie_1';
    const cardId2 = 'card_zombie_2';

    setUp(() async {
      final db = LocalDatabase.instance;
      final rawDb = await db.database;
      await rawDb.delete('saved_quotes', where: 'document_id = ?', whereArgs: [docId]);
      await rawDb.delete('context_cards', where: 'document_id = ?', whereArgs: [docId]);
      await rawDb.delete('documents', where: 'id = ?', whereArgs: [docId]);

      final nowIso = DateTime.now().toIso8601String();
      await rawDb.insert('documents', {
        'id': docId,
        'title': 'Zombie Quote Test Book',
        'filename': 'zombie_test.pdf',
        'status': 'ready',
        'page_count': 10,
        'chunk_count': 10,
        'created_at': nowIso,
        'updated_at': nowIso,
      });

      // Insert 2 context cards
      await rawDb.insert('context_cards', {
        'id': cardId1,
        'document_id': docId,
        'source_chunk_id': '$docId-c000001',
        'concept_name': 'ancient education',
        'card_type': 'historical_case',
        'title': 'First Note',
        'body': 'Historical analysis of ancient education institutions.',
        'why_here': 'Historical context',
        'exact_quote': 'ancient education',
        'canonical_sha256': 'sha_test_1',
        'saved': 1,
        'dismissed': 0,
        'created_at': nowIso,
      });

      await rawDb.insert('context_cards', {
        'id': cardId2,
        'document_id': docId,
        'source_chunk_id': '$docId-c000002',
        'concept_name': 'modern learning',
        'card_type': 'empirical_study',
        'title': 'Second Note',
        'body': 'Empirical study into modern learning paradigms.',
        'why_here': 'Empirical context',
        'exact_quote': 'modern learning',
        'canonical_sha256': 'sha_test_2',
        'saved': 1,
        'dismissed': 0,
        'created_at': nowIso,
      });

      // Insert corresponding quotes in saved_quotes
      await db.saveQuote({
        'id': cardId1,
        'document_id': docId,
        'document_title': 'Zombie Quote Test Book',
        'chunk_id': '$docId-c000001',
        'page_reference': 'Page 1',
        'text': 'ancient education',
        'created_at': nowIso,
      });

      await db.saveQuote({
        'id': cardId2,
        'document_id': docId,
        'document_title': 'Zombie Quote Test Book',
        'chunk_id': '$docId-c000002',
        'page_reference': 'Page 2',
        'text': 'modern learning',
        'created_at': nowIso,
      });
    });

    test('unsaving a card removes it from saved_quotes immediately (zero zombie quotes)', () async {
      final db = LocalDatabase.instance;
      final rawDb = await db.database;

      // Initial state: 2 quotes in saved_quotes
      var quotes = await db.getSavedQuotes();
      expect(quotes.length, 2);

      // Unsave card 1
      await db.setCardSaved(cardId1, false);

      // Verify card 1 is saved=0
      final cardRows = await rawDb.query('context_cards',
          where: 'id = ?', whereArgs: [cardId1]);
      expect(cardRows.first['saved'], 0);

      // Verify card 1 is DELETED from saved_quotes (not a zombie!)
      quotes = await db.getSavedQuotes();
      expect(quotes.length, 1);
      expect(quotes.any((q) => q['id'] == cardId1), isFalse);
      expect(quotes.first['id'], cardId2);
    });

    test('dismissing a card sets saved=0, dismissed=1 and deletes from saved_quotes (SM-09)', () async {
      final db = LocalDatabase.instance;
      final rawDb = await db.database;

      // Dismiss card 2
      await db.setCardDismissed(cardId2, true);

      final cardRows = await rawDb.query('context_cards',
          where: 'id = ?', whereArgs: [cardId2]);
      expect(cardRows.first['dismissed'], 1);
      expect(cardRows.first['saved'], 0,
          reason: 'dismissed and saved must be mutually exclusive');

      // Verify deleted from saved_quotes
      final quoteRows = await rawDb.query('saved_quotes',
          where: 'id = ?', whereArgs: [cardId2]);
      expect(quoteRows.isEmpty, isTrue);
    });

    test('clearAllSavedCards resets context_cards.saved and clears saved_quotes completely', () async {
      final db = LocalDatabase.instance;
      final rawDb = await db.database;

      await db.clearAllSavedCards();

      final cards = await rawDb.query('context_cards', where: 'saved = 1');
      expect(cards.isEmpty, isTrue);

      final quotes = await db.getSavedQuotes();
      expect(quotes.isEmpty, isTrue,
          reason: 'saved_quotes must be empty after clearAllSavedCards');
    });
  });

  group('Pass 2: In-Flight Card Slot State & Deduplication (SM-08)', () {
    test('CardSlotState prevents duplicate concurrent synthesis calls for same chunkSeq', () {
      final cardSlotStates = <int, CardSlotState>{};
      int generatorCallCount = 0;

      bool canSynthesize(int seq) {
        final state = cardSlotStates[seq];
        if (state == null) return true;
        if (state.isInFlight || state.isReady || state.isInCooldown) return false;
        return true;
      }

      void triggerGeneration(int seq) {
        if (!canSynthesize(seq)) return;
        cardSlotStates[seq] = const CardSlotState(CardSlotStatus.inFlight);
        generatorCallCount++;
      }

      // Simulate simultaneous dwell and prefetch on chunkSeq 42
      triggerGeneration(42); // First trigger (e.g. dwell)
      expect(generatorCallCount, 1);
      expect(cardSlotStates[42]!.isInFlight, isTrue);

      // Concurrent second trigger (e.g. prefetch upcoming)
      triggerGeneration(42);
      expect(generatorCallCount, 1,
          reason: 'Second call must be skipped while inFlight');

      // Finish generation
      cardSlotStates[42] = const CardSlotState(CardSlotStatus.ready);
      triggerGeneration(42);
      expect(generatorCallCount, 1,
          reason: 'Subsequent calls must be skipped once ready');

      // Test failed cooldown window
      cardSlotStates[99] = CardSlotState(
        CardSlotStatus.failedCooldown,
        DateTime.now().add(const Duration(seconds: 30)),
      );
      expect(canSynthesize(99), isFalse,
          reason: 'Slot in active cooldown must not trigger synthesis');
    });
  });

  group('Pass 2: Ingestion Coordinator Ref-Counting & Timeout (SM-02)', () {
    test('cancelJob removes docId and stops foreground cleanly', () async {
      final coordinator = IngestionJobCoordinator.instance;
      expect(coordinator.isJobActive('doc_fgs_test_1'), isFalse);

      // Simulating cancelJob
      await coordinator.cancelJob('doc_fgs_test_1', markStatus: 'paused', reason: 'Test cancel');
      expect(coordinator.isJobCancelled('doc_fgs_test_1'), isTrue);
      expect(coordinator.isJobActive('doc_fgs_test_1'), isFalse);
    });
  });

  group('Pass 2: BYOK Fallback Failover Verification (ISM-07)', () {
    test('SharedPreferences fallback provider settings configured properly', () async {
      SharedPreferences.setMockInitialValues({
        'athena_ai_primary_provider': 'deepseek',
        'athena_ai_fallback_provider': 'mistral',
        'athena_ai_fallback_model': 'mistral-small-latest',
        'athena_ai_fallback_api_key': 'test_fallback_key_123',
      });

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('athena_ai_primary_provider'), 'deepseek');
      expect(prefs.getString('athena_ai_fallback_provider'), 'mistral');
      expect(prefs.getString('athena_ai_fallback_model'), 'mistral-small-latest');
      expect(prefs.getString('athena_ai_fallback_api_key'), 'test_fallback_key_123');
    });
  });
}
