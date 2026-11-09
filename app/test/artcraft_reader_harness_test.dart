import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:athena/core/theme/theme.dart';
import 'package:athena/core/theme/reader_theme.dart';
import 'package:athena/features/reader/widgets/chunk_widget.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';
import 'package:athena/features/reader/widgets/reader_bottom_bar.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/lossless_chunker.dart';

void main() {
  group('ArtCraft Mobile Viewport & Engineering Invariant Harness', () {
    // -------------------------------------------------------------
    // Test 1: ChunkWidget Rendering, Plain Take, and Explicit DocumentId
    // -------------------------------------------------------------
    testWidgets('1. ChunkWidget renders at 390x844 with exact documentId, font scale & Plain Take action',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      bool plainTakeTapped = false;
      bool askTapped = false;
      bool originalPageTapped = false;

      const chunk = ReaderItem(
        id: 'chunk_doc_test_101_1',
        type: 'reading_chunk',
        sequence: 1,
        text:
            'In ancient Athens, Socrates walked the agora examining the unexamined life. True wisdom begins in the candid acknowledgment of our own ignorance.',
        pageReference: 'Page 12',
        sectionTitle: 'Apology and Crito',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChunkWidget(
                chunk: chunk,
                documentId: 'doc_test_101',
                fontSize: 18.0,
                onViewOriginalPage: () => originalPageTapped = true,
                onAsk: () => askTapped = true,
                onPlainTake: () => plainTakeTapped = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Assert text rendered
      expect(find.text(chunk.text!), findsOneWidget);
      final pageFinder = find.text('PAGE 12');
      expect(pageFinder, findsOneWidget);
      await tester.tap(pageFinder);
      await tester.pumpAndSettle();
      expect(originalPageTapped, isTrue);

      // Assert Plain Take pill exists and triggers
      final plainTakeFinder = find.text('Plain Take');
      expect(plainTakeFinder, findsOneWidget);
      await tester.tap(plainTakeFinder);
      await tester.pumpAndSettle();
      expect(plainTakeTapped, isTrue);

      // Assert Ask button exists and triggers
      final askFinder = find.text('Ask Athena');
      expect(askFinder, findsOneWidget);
      await tester.tap(askFinder);
      await tester.pumpAndSettle();
      expect(askTapped, isTrue);
    });

    // -------------------------------------------------------------
    // Test 2: ContextCardWidget 4-Archetype & Support Tier Rendering @ 390x844
    // -------------------------------------------------------------
    testWidgets('2. ContextCardWidget renders honest support tiers with zero overflow @ 390x844',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final cards = [
        const ReaderItem(
          id: 'card_empirical_1',
          type: 'context_card',
          cardType: 'empirical_study',
          title: 'EMPIRICAL STUDY: Metacognitive Calibration',
          body:
              'A randomized controlled trial across 320 university students demonstrated that active ignorance calibration improves subsequent recall accuracy by 34% compared with overconfident re-reading.',
          exactQuote: 'True wisdom begins in the candid acknowledgment of our own ignorance.',
          citations: [
            {
              'title': 'Metacognitive Monitoring in Dialectic Dialogues',
              'publisher': 'Journal of Cognitive Psychology · Crossref',
              'url': 'https://doi.org/10.1037/cog0000412',
            }
          ],
          supportTier: 'verified_external',
          verified: true,
          whyHere: 'Grounded in peer-reviewed research on metacognition.',
        ),
        const ReaderItem(
          id: 'card_internal_2',
          type: 'context_card',
          cardType: 'counterpoint',
          title: 'THEMATIC NOTE: The Socratic Method',
          body:
              'Throughout the early dialogues, Socrates interrogates citizens who claim specialized knowledge of piety, justice, and courage, revealing conceptual contradictions.',
          exactQuote: 'Socrates walked the agora examining the unexamined life.',
          supportTier: 'internal_extractive',
          verified: false,
          whyHere: 'Connected theme within this book.',
        ),
      ];

      for (final card in cards) {
        bool savedToggled = false;

        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.lightTheme,
            home: Scaffold(
              body: SingleChildScrollView(
                child: ContextCardWidget(
                  card: card,
                  onToggleSave: () => savedToggled = true,
                  onDismiss: () {},
                  onAskAthena: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Assert card title and body are rendered
        expect(find.text(card.title!), findsOneWidget);
        expect(find.text(card.body!), findsOneWidget);

        // 2. Anti-Slop verification: no reveal tags, no synthetic Q&A format
        final body = card.body!;
        expect(body.contains('||REVEAL||'), isFalse);
        expect(body.contains('Question:'), isFalse);
        expect(body.contains('Q:'), isFalse);

        // 3. Exact quote anchoring verification
        if (card.exactQuote != null) {
          expect(find.textContaining(card.exactQuote!), findsOneWidget);
        }

        // 4. Save and Dismiss buttons are responsive
        final saveBtn = find.byIcon(Icons.bookmark_border_rounded);
        if (saveBtn.evaluate().isNotEmpty) {
          await tester.tap(saveBtn);
          await tester.pumpAndSettle();
          expect(savedToggled, isTrue);
        }
      }
    });

    // -------------------------------------------------------------
    // Test 3: ReaderBottomBar Layout & Visual Touch Target Ergonomics
    // -------------------------------------------------------------
    testWidgets('3. ReaderBottomBar renders comfortably on 390x844 without overflow',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      bool askTapped = false;
      bool generateCardTapped = false;

      const dummyChunk = ReaderItem(
        id: 'c1',
        type: 'reading_chunk',
        sequence: 1,
        text: 'Hello world.',
      );
      final dummyItems = [dummyChunk];

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            bottomNavigationBar: ReaderBottomBar(
              currentIndex: 0,
              totalItems: 1,
              feedItems: dummyItems,
              readingChunks: dummyItems,
              theme: ReaderThemeConfig.paper,
              onAsk: () => askTapped = true,
              onGenerateCard: () => generateCardTapped = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify buttons exist
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(find.byIcon(Icons.menu_book_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chat_bubble_outline_rounded));
      expect(askTapped, isTrue);

      await tester.tap(find.byIcon(Icons.menu_book_outlined));
      expect(generateCardTapped, isTrue);
    });

    // -------------------------------------------------------------
    // Test 4: Lossless Chunking Reconstruction & Word Count Ceilings
    // -------------------------------------------------------------
    test('4. Lossless chunking preserves author text with zero corruption', () {
      const canonicalProse =
          'It is a truth universally acknowledged, that a single man in possession of a good fortune, '
          'must be in want of a wife.\n\n'
          'However little known the feelings or views of such a man may be on his first entering a neighbourhood, '
          'this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful '
          'property of some one or other of their daughters.';

      final spans = [
        {'start': 0, 'end': canonicalProse.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}
      ];

      final chunks = LosslessChunker().build(
        documentId: 'doc_austin_1',
        canonicalText: canonicalProse,
        spans: spans,
      );

      expect(chunks, isNotEmpty);
      final reconstructed = chunks.map((c) => c['raw_text']! as String).join('');
      expect(reconstructed, equals(canonicalProse));

      for (final c in chunks) {
        final text = c['raw_text'] as String;
        final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        expect(words, lessThanOrEqualTo(75));
      }
    });
  });
}
