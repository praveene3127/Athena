import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

void main() {
  group('ContextCardWidget Instant Editorial Fact Tests', () {
    testWidgets('renders verified factual study with ZERO reveals, ZERO Q&A, and verified source pill',
        (tester) async {
      const cardItem = ReaderItem(
        id: 'c-101-card',
        type: 'context_card',
        cardType: 'real_world_study',
        title: 'REAL-WORLD STUDY: Athenian Philosophical Academy',
        body:
            'Empirical investigations into Athenian philosophical academies demonstrate documented links between structured dialectic dialogue and long-term ethical reasoning across historical cohorts.',
        exactQuote:
            'In ancient Athens, the philosophical academy gathered outside the city walls to debate human character and ethical discipline.',
        citations: [
          {
            'title': 'Athenian Philosophical Lineage Study',
            'publisher': 'Journal of Classical History (2019) · Crossref',
            'url': 'https://doi.org/10.1017/jch.2019.42',
          }
        ],
        verified: true,
        supportStatus: 'verified',
      );

      final body = cardItem.body ?? '';
      final title = cardItem.title ?? '';

      // Terminal proof print
      debugPrint('\n=== [TERMINAL PROOF: CONTEXT CARD RENDERING] ===');
      debugPrint('+ Title: $title');
      debugPrint('+ Body: $body');
      debugPrint('+ Verified: ${cardItem.isVerified}');
      debugPrint('================================================\n');

      // Assertions on card content
      expect(body.contains('||REVEAL||'), isFalse,
          reason: 'Context card must NEVER contain ||REVEAL|| delimiters');
      expect(body.contains('Question:'), isFalse,
          reason: 'Context card must NEVER format as Question & Answer');
      expect(body.contains('Q:'), isFalse);
      expect(body.contains('?'), isFalse);

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
      expect(find.textContaining('Empirical investigations into Athenian'),
          findsOneWidget);

      // 5. Verified Source Footer and verified icon verified
      expect(find.textContaining('SOURCE: JOURNAL OF CLASSICAL HISTORY'), findsOneWidget);
      expect(find.byIcon(Icons.verified_rounded), findsOneWidget);

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
        verified: true,
        supportStatus: 'verified',
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
