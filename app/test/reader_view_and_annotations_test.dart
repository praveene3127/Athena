import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/features/reader/controllers/reader_feed_builder.dart';
import 'package:athena/features/reader/screens/reader_screen.dart';
import 'package:athena/features/reader/widgets/reader_bottom_bar.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';
import 'package:athena/features/settings/widgets/byok_settings_sheet.dart';

void main() {
  group('ArtCraft Mobile Viewport & Engineering Invariant Harness', () {
    // -------------------------------------------------------------
    // Test 1: Word Spacing & Single-Screen Chunk Invariant
    // -------------------------------------------------------------
    test('Test 1 - Word Spacing & Single-Screen Chunk Invariant', () {
      const rawTextWithKerning =
          'candle.HeadmasterGaleNolan,ahusky boy who carried banners.\n'
          'Thefourboyswhocarriedbannersmarchedsolemnlytothedais, '
          'followedslowlybytheelderlymen, thelastofwhomproudlycarriedthelightedcandle. '
          'Headmaster Gale Nolan, '
          'ahuskymaninhisearlysixties, stoodatthepodiumwatchingexpectantlyastheprocessionconcluded. '
          '“Ladiesandgentlemen...boys...” '
          'hesaiddramatically, pointingtowardthemanwiththecandle. '
          '“Thelightofknowledge.” Theaudienceapplaudedpolitelyastheoldergentlemansteppedslowlyforwardwiththecandle.';

      final sanitized = sanitizeProseSpacing(rawTextWithKerning);

      // 1. Spacing invariant: words separated properly
      expect(sanitized, contains('Headmaster Gale Nolan'));
      expect(sanitized, contains('a husky man in his early sixties'));
      expect(sanitized, contains('The four boys who carried banners marched solemnly to the dais'));
      expect(sanitized, contains('followed slowly by the elderly men'));

      // 2. Chunker invariant: chunks must not overflow single mobile screen (< 75 words, <= 450 chars)
      final spans = <Map<String, dynamic>>[
        {'start': 0, 'end': sanitized.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}
      ];
      final chunks = LosslessChunker().build(
        documentId: 'doc_artcraft',
        canonicalText: sanitized,
        spans: spans,
      );

      expect(chunks, isNotEmpty);
      for (final chunk in chunks) {
        final text = chunk['raw_text']! as String;
        final wordCount = text.trim().split(RegExp(r'\s+')).length;
        expect(wordCount, lessThanOrEqualTo(75),
            reason: 'Chunk exceeded word ceiling: $wordCount words');
        expect(text.length, lessThanOrEqualTo(450),
            reason: 'Chunk exceeded char ceiling: ${text.length} chars');
      }

      // 3. Lossless reconstruction invariant
      final reconstructed = chunks.map((c) => c['raw_text']! as String).join('');
      expect(reconstructed, equals(sanitized));
    });

    // -------------------------------------------------------------
    // Test 2: Deterministic Context Card Interleaving & 4-Archetype Formatting
    // -------------------------------------------------------------
    test('Test 2 - Deterministic Context Card Interleaving & 4-Archetype Formatting', () async {
      final rawChunks = List.generate(
        8,
        (i) => ReaderItem(
          id: 'chunk_${i + 1}',
          type: 'reading_chunk',
          sequence: i + 1,
          text: 'Passage segment ${i + 1} exploring empirical observations of philosophy and historical evidence in action.',
          pageReference: 'Page ${(i ~/ 2) + 1}',
        ),
      );

      // Dynamic cards with 4 archetypes
      final dynamicCards = {
        2: const ReaderItem(
          id: 'card_empirical',
          type: 'context_card',
          sequence: 2,
          insertAfter: 'chunk_2',
          title: 'EMPIRICAL STUDY: Cognitive Behavioral Effects',
          body: 'Question: What was observed?\n||REVEAL||\nParticipants showed a marked reduction in rumination.',
          exactQuote: 'empirical observations',
        ),
        5: const ReaderItem(
          id: 'card_critical',
          type: 'context_card',
          sequence: 5,
          insertAfter: 'chunk_5',
          title: 'CRITICAL DEBATE: Methodological Counterpoint',
          body: 'Counterpoint: Alternative interpretations suggest non-linear responses.',
          exactQuote: 'historical evidence in action',
        ),
        // One unassigned card to verify deterministic fallback
        99: const ReaderItem(
          id: 'card_unassigned',
          type: 'context_card',
          insertAfter: 'unmatched_target_chunk',
          title: 'HISTORICAL CONTEXT: Classical Antecedents',
          body: 'Historical documentation confirms this pattern in early institutional models.',
          exactQuote: 'Passage segment',
        ),
      };

      final feed = buildInterleavedFeed(
        rawItems: rawChunks,
        dynamicCardsBySeq: dynamicCards,
        dismissedCardIds: {},
        showContextCards: true,
      );

      // Verify at least 1 context card interleaved every 3-4 chunks
      final cardsInFeed = feed.where((it) => it.isContextCard).toList();
      expect(cardsInFeed.length, greaterThanOrEqualTo(2));

      // Verify valid archetype prefixes
      final validArchetypes = [
        'EMPIRICAL STUDY',
        'CRITICAL DEBATE',
        'HISTORICAL CONTEXT',
        'CORE PARADOX'
      ];
      for (final card in cardsInFeed) {
        final title = card.title ?? '';
        final hasArchetype = validArchetypes.any((arch) => title.contains(arch));
        expect(hasArchetype, isTrue, reason: 'Card title "$title" lacks archetype prefix');
      }

      // Verify exactQuote is anchored in corresponding chunk
      for (final card in cardsInFeed) {
        if (card.exactQuote != null && card.exactQuote!.isNotEmpty) {
          final matchedChunk = rawChunks.any((c) => c.rawText.contains(card.exactQuote!));
          expect(matchedChunk, isTrue,
              reason: 'Card quote "${card.exactQuote}" not found in source text');
        }
      }

      // Verify unassigned card was deterministically placed, never dropped!
      expect(feed.any((it) => it.id == 'card_unassigned'), isTrue);
    });

    // -------------------------------------------------------------
    // Test 3: 390x844 Mobile Viewport UI & Snap-Scroll Test
    // -------------------------------------------------------------
    testWidgets('Test 3 - 390x844 Mobile Viewport UI & Snap-Scroll Test', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockChunks = [
        const ReaderItem(
          id: 'c1',
          type: 'reading_chunk',
          sequence: 1,
          text: 'The first chapter begins with profound stillness across the valley.',
          pageReference: 'Page 1',
        ),
        const ReaderItem(
          id: 'card1',
          type: 'context_card',
          sequence: 1,
          insertAfter: 'c1',
          title: 'HISTORICAL CONTEXT: Geographic Origins',
          body: 'Geological surveys dated the valley formation to the late Pleistocene epoch.',
          exactQuote: 'profound stillness',
        ),
        const ReaderItem(
          id: 'c2',
          type: 'reading_chunk',
          sequence: 2,
          text: 'As morning advanced, the expedition prepared their navigational instruments.',
          pageReference: 'Page 2',
        ),
      ];

      final testData = ReaderData(
        docId: 'doc_viewport_test',
        title: 'Expedition Journal',
        pageCount: 2,
        chunkCount: 2,
        layoutWarning: null,
        contextStatus: 'ready',
        integrityVerified: true,
        items: mockChunks,
        cards: [mockChunks[1]],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            readerDataProvider('doc_viewport_test')
                .overrideWith((ref) => Future.value(testData)),
          ],
          child: const MaterialApp(
            home: ReaderScreen(documentId: 'doc_viewport_test'),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Zero Flutter errors or RenderFlex overflows
      expect(tester.takeException(), isNull);

      // Verify PageView is present
      final pageViewFinder = find.byType(PageView);
      expect(pageViewFinder, findsOneWidget);

      // Verify ReaderBottomBar is present and does not overlap the card
      final bottomBarFinder = find.byType(ReaderBottomBar);
      expect(bottomBarFinder, findsOneWidget);

      final bottomBarRect = tester.getRect(bottomBarFinder);
      final pageViewRect = tester.getRect(pageViewFinder);

      // PageView is completely above ReaderBottomBar
      expect(pageViewRect.bottom, lessThanOrEqualTo(bottomBarRect.top + 1.0));
      expect(pageViewRect.overlaps(bottomBarRect), isFalse,
          reason: 'Bottom bar overlaps the reading viewport');

      // Vertical swipe snaps cleanly from page 0 to page 1
      await tester.fling(pageViewFinder, const Offset(0, -500), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Should land on the next item (ContextCardWidget)
      expect(find.byType(ContextCardWidget), findsOneWidget);
    });

    // -------------------------------------------------------------
    // Test 4: BYOKSettingsSheet Keyboard Crush & Zero Static Models Test
    // -------------------------------------------------------------
    testWidgets('Test 4 - BYOKSettingsSheet Keyboard Crush & Zero Static Models Test', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Pump BYOKSettingsSheet with simulated keyboard insets
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              viewInsets: EdgeInsets.only(bottom: 340), // 340px keyboard
            ),
            child: const Scaffold(
              body: BYOKSettingsSheet(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Zero layout overflow under 340px keyboard crush
      expect(tester.takeException(), isNull);

      // Assert DropdownButton is NEVER used (ArtCraft Law 3 / Architectural Rule)
      expect(find.byType(DropdownButton), findsNothing);

      // Assert zero hardcoded static model IDs in the widget tree before connection check
      const forbiddenModels = [
        'gemini-2.5-flash',
        'gemini-2.5-pro',
        'gemini-2.0-flash',
        'gpt-4o',
        'claude-3',
        'llama-3'
      ];
      for (final model in forbiddenModels) {
        expect(find.text(model), findsNothing,
            reason: 'Hardcoded static model "$model" found in UI before connection check');
      }
    });
  });
}
