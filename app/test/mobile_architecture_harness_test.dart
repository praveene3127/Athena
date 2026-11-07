import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/features/reader/controllers/reader_feed_builder.dart';
import 'package:athena/features/reader/screens/reader_screen.dart';
import 'package:athena/features/reader/widgets/reader_bottom_bar.dart';
import 'package:athena/features/reader/widgets/chunk_widget.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';
import 'package:athena/features/settings/widgets/byok_settings_sheet.dart';

void main() {
  group('Mobile Architecture & Geometry Harness (390x844 Viewport)', () {
    // -------------------------------------------------------------
    // Test 1: Zero Overlaps & Discrete Bounding Box Geometry
    // -------------------------------------------------------------
    testWidgets('1. Zero Overlaps: Reading card and Context Card never overlap Top or Bottom bar', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockChunks = [
        const ReaderItem(
          id: 'chunk_geo_1',
          type: 'reading_chunk',
          sequence: 1,
          text: 'The academic year opened in September with crisp morning air across the campus lawn.',
          pageReference: 'Page 1 (1/1)',
        ),
        const ReaderItem(
          id: 'card_geo_1',
          type: 'context_card',
          sequence: 1,
          insertAfter: 'chunk_geo_1',
          title: 'HISTORICAL CONTEXT: New England Academies',
          body: 'Traditional preparatory schools in the northeastern United States emphasized rigorous classical formation.\n||REVEAL||\nArchival enrollment data confirmed small cohort sizes designed for intensive tutorial instruction.',
          exactQuote: 'academic year opened in September',
        ),
      ];

      final testData = ReaderData(
        docId: 'doc_geo_test',
        title: 'Dead Poets Society',
        pageCount: 1,
        chunkCount: 1,
        layoutWarning: null,
        contextStatus: 'ready',
        integrityVerified: true,
        items: mockChunks,
        cards: [mockChunks[1]],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            readerDataProvider('doc_geo_test')
                .overrideWith((ref) => Future.value(testData)),
          ],
          child: const MaterialApp(
            home: ReaderScreen(documentId: 'doc_geo_test'),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull);

      final appBarFinder = find.byType(AppBar);
      final bottomBarFinder = find.byType(ReaderBottomBar);
      final pageViewFinder = find.byType(PageView);
      final chunkFinder = find.byType(ChunkWidget);

      expect(appBarFinder, findsOneWidget);
      expect(bottomBarFinder, findsOneWidget);
      expect(pageViewFinder, findsOneWidget);
      expect(chunkFinder, findsOneWidget);

      final appBarRect = tester.getRect(appBarFinder);
      final bottomBarRect = tester.getRect(bottomBarFinder);
      final pageViewRect = tester.getRect(pageViewFinder);
      final chunkRect = tester.getRect(chunkFinder);

      // Verify zero overlap between page content and top/bottom navigation chrome
      expect(chunkRect.top, greaterThanOrEqualTo(appBarRect.bottom - 1.0),
          reason: 'ChunkWidget bled upward into the AppBar');
      expect(chunkRect.bottom, lessThanOrEqualTo(bottomBarRect.top + 1.0),
          reason: 'ChunkWidget bled downward into ReaderBottomBar');
      expect(pageViewRect.overlaps(bottomBarRect), isFalse,
          reason: 'PageView viewport overlaps ReaderBottomBar');
      expect(chunkRect.overlaps(bottomBarRect), isFalse,
          reason: 'Chunk card overlaps ReaderBottomBar');
    });

    // -------------------------------------------------------------
    // Test 2: Zero Overflows with 340px Keyboard Open
    // -------------------------------------------------------------
    testWidgets('2. Zero Overflows: Modals and settings survive 340px software keyboard', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      // Simulate 340px keyboard opening
      tester.view.viewInsets = const FakeViewPadding(bottom: 340 * 3.0);

      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetViewInsets();
      });

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: BYOKSettingsSheet(),
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      // Absolutely zero RenderFlex overflows
      expect(tester.takeException(), isNull);
    });

    // -------------------------------------------------------------
    // Test 3: 1-Swipe = 1-Card Snap Physics in Feed Mode
    // -------------------------------------------------------------
    testWidgets('3. 1-Swipe = 1-Card Snap: PageView advances by exactly 1 card per swipe', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockItems = [
        const ReaderItem(
          id: 'chunk_snap_1',
          type: 'reading_chunk',
          sequence: 1,
          text: 'First passage text discussing initial historical observations.',
          pageReference: 'Page 1',
        ),
        const ReaderItem(
          id: 'card_snap_1',
          type: 'context_card',
          sequence: 1,
          insertAfter: 'chunk_snap_1',
          title: 'EMPIRICAL STUDY: Historical Origins',
          body: 'Empirical verification.\n||REVEAL||\nDetailed evidence.',
          exactQuote: 'initial historical observations',
        ),
        const ReaderItem(
          id: 'chunk_snap_2',
          type: 'reading_chunk',
          sequence: 2,
          text: 'Second passage text continuing the narrative exposition.',
          pageReference: 'Page 2',
        ),
      ];

      final testData = ReaderData(
        docId: 'doc_snap_test',
        title: 'Snap Test Document',
        pageCount: 2,
        chunkCount: 2,
        layoutWarning: null,
        contextStatus: 'ready',
        integrityVerified: true,
        items: mockItems,
        cards: [mockItems[1]],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            readerDataProvider('doc_snap_test')
                .overrideWith((ref) => Future.value(testData)),
          ],
          child: const MaterialApp(
            home: ReaderScreen(documentId: 'doc_snap_test'),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final pageViewFinder = find.byType(PageView);
      expect(pageViewFinder, findsOneWidget);

      // Verify on page 0 initially (chunk 1)
      expect(find.textContaining('First passage text'), findsOneWidget);
      expect(find.byType(ContextCardWidget), findsNothing);

      // Perform a single vertical drag upward
      await tester.fling(pageViewFinder, const Offset(0, -500), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Snap landed cleanly on page 1 (the interleaved ContextCard)
      expect(find.byType(ContextCardWidget), findsOneWidget);
      expect(find.textContaining('EMPIRICAL STUDY: Historical Origins'), findsOneWidget);
      expect(find.textContaining('Second passage text'), findsNothing);

      // Perform second vertical drag upward
      await tester.fling(pageViewFinder, const Offset(0, -500), 1200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // Snap landed cleanly on page 2 (chunk 2)
      expect(find.textContaining('Second passage text'), findsOneWidget);
    });

    // -------------------------------------------------------------
    // Test 4: Data Integrity & Word Spacing
    // -------------------------------------------------------------
    test('4. Data Integrity: Word spacing sanitized & Context Cards interleaved', () {
      const fusedRaw = 'Thefouryoungstudentswhocarriedbookswalkedslowlytotheschool.';
      final clean = sanitizeProseSpacing(fusedRaw);
      expect(clean, equals('The four young students who carried books walked slowly to the school.'));

      final chunks = [
        ReaderItem(id: 'c1', type: 'reading_chunk', sequence: 1, text: clean),
        const ReaderItem(id: 'c2', type: 'reading_chunk', sequence: 2, text: 'Second chunk.'),
      ];
      final cards = {
        1: const ReaderItem(
          id: 'card1',
          type: 'context_card',
          sequence: 1,
          insertAfter: 'c1',
          title: 'HISTORICAL CONTEXT: Banner Traditions',
          body: 'Historical documentation.',
          exactQuote: 'banners marched solemnly',
        ),
      };

      final feed = buildInterleavedFeed(
        rawItems: chunks,
        dynamicCardsBySeq: cards,
        dismissedCardIds: {},
        showContextCards: true,
      );

      expect(feed.length, equals(3));
      expect(feed[0].id, equals('c1'));
      expect(feed[1].id, equals('card1'));
      expect(feed[2].id, equals('c2'));
    });
  });
}
