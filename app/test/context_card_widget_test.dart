import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';
import 'package:athena/services/local_context_service.dart';

void main() {
  group('ContextCardWidget Instant Editorial Fact Tests', () {
    testWidgets('generates and renders instant factual study with ZERO reveals and ZERO Q&A',
        (tester) async {
      final service = LocalContextService();
      final chunkMap = {
        'id': 'c-101',
        'sequence': 6,
        'raw_text':
            'In ancient Athens, the philosophical academy gathered outside the city walls to debate human character and ethical discipline.',
      };

      // 1. Generate local draft fact card
      final draft = service.generateSpeculativeDraftCard('doc-1', chunkMap, 0);
      final draftBody = draft['body'] as String;
      final draftTitle = draft['title'] as String;

      // Terminal proof print
      debugPrint('\n=== [TERMINAL PROOF: CONTEXT CARD GENERATION] ===');
      debugPrint('+ Title: $draftTitle');
      debugPrint('+ Body: $draftBody');
      debugPrint('+ Citations: ${draft['citations_json']}');
      debugPrint('================================================\n');

      // Assertions on generated card content
      expect(draftBody.contains('||REVEAL||'), isFalse,
          reason: 'Context card must NEVER contain ||REVEAL|| delimiters');
      expect(draftBody.contains('Question:'), isFalse,
          reason: 'Context card must NEVER format as Question & Answer');
      expect(draftBody.contains('Q:'), isFalse);
      expect(draftBody.contains('?'), isFalse);

      final cardItem = ReaderItem.fromJson({
        ...draft,
        'citations': [
          {
            'title': 'Athenian Philosophical Lineage Study',
            'publisher': 'Journal of Classical History (2019) · Crossref',
            'url': 'https://doi.org/10.1017/jch.2019.42',
          }
        ],
      });

      bool saved = false;
      bool dismissed = false;

      // Set physical phone viewport: 390x844 (iPhone 15 Pro / standard mobile)
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContextCardWidget(
                card: cardItem,
                onToggleSave: () => saved = true,
                onDismiss: () => dismissed = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Zero reveal buttons or text on screen
      expect(find.textContaining('REVEAL'), findsNothing,
          reason: 'Context Card UI must NEVER show reveal buttons');
      expect(find.textContaining('Tap to reveal'), findsNothing);
      expect(find.textContaining('Reveal'), findsNothing);

      // 2. Eyebrow badge verified
      expect(find.text('REAL-WORLD STUDY'), findsOneWidget);

      // 3. Anchor line verified
      expect(find.textContaining('Re: '), findsOneWidget);

      // 4. Full declarative body is 100% visible immediately without tapping anything
      expect(find.textContaining('alters autonomic nervous activity by over 32%'),
          findsOneWidget);
      expect(find.textContaining('In documented investigations into'),
          findsNothing);

      // 5. Verified Source Footer verified
      expect(find.textContaining('SOURCE: JOURNAL OF CLASSICAL HISTORY'), findsOneWidget);

      // 6. Save & Dismiss buttons operate
      await tester.tap(find.byTooltip('Save Fact'));
      expect(saved, isTrue);

      await tester.tap(find.byTooltip('Dismiss'));
      expect(dismissed, isTrue);
    });

    testWidgets('cleans legacy ||REVEAL|| and Q&A formatting from legacy cards',
        (tester) async {
      const legacyItem = ReaderItem(
        id: 'legacy-1',
        type: 'context_card',
        cardType: 'explain',
        title: 'REAL-WORLD STUDY: Monastic Health Findings',
        body:
            'Question: Did monastic silence improve cardiovascular metrics?\n||REVEAL||\nEmpirical observations recorded a 34% reduction in systolic blood pressure.',
        exactQuote: 'The monks embraced structured silence throughout the seasons.',
        citations: [
          {
            'publisher': 'The Lancet (2018) · Europe PMC',
            'url': 'https://doi.org/10.1016/S0140-6736',
          }
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ContextCardWidget(
                card: legacyItem,
                onToggleSave: () {},
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Zero reveal buttons or delimiters
      expect(find.textContaining('REVEAL'), findsNothing);
      expect(find.textContaining('||REVEAL||'), findsNothing);
      expect(find.textContaining('Question:'), findsNothing);

      // The full text is clean declarative prose
      expect(find.textContaining('Empirical observations recorded a 34% reduction'), findsOneWidget);
      expect(find.textContaining('SOURCE: THE LANCET (2018) · EUROPE PMC'), findsOneWidget);
    });
  });
}
