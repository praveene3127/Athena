import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

void main() {
  group('ContextCardWidget Tests', () {
    testWidgets('renders Empirical Study card with interactive spoiler reveal',
        (tester) async {
      const cardItem = ReaderItem(
        id: 'card-1',
        type: 'context_card',
        cardType: 'explain',
        title: 'EMPIRICAL STUDY: Stoic Practice Effects',
        body:
            'Question: What was the result of the randomized trial?\n||REVEAL||\nParticipants showed a 28% reduction in chronic stress markers.',
        citations: [
          {
            'title': 'Cognitive Stress Inversion',
            'publisher': 'Academic Press',
            'url': 'https://example.com/study',
          },
        ],
        exactQuote: 'Practice virtue every hour.',
      );

      bool saved = false;
      bool dismissed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextCardWidget(
              card: cardItem,
              onToggleSave: () => saved = true,
              onDismiss: () => dismissed = true,
            ),
          ),
        ),
      );

      // Verify Eyebrow archetype badge
      expect(find.text('EMPIRICAL STUDY'), findsOneWidget);
      expect(find.text('Stoic Practice Effects'), findsOneWidget);

      // Verify question part is visible
      expect(
          find.textContaining('Question: What was the result'), findsOneWidget);

      // Initially the reveal action button is visible
      expect(find.text('Reveal Study Findings'), findsOneWidget);

      // Tap Reveal button
      await tester.tap(find.text('Reveal Study Findings'));
      await tester.pumpAndSettle();

      // Now revealed finding is visible
      expect(find.textContaining('28% reduction in chronic stress markers.'),
          findsOneWidget);
      expect(find.text('STUDY FINDINGS'), findsOneWidget);

      // Verify citation publisher
      expect(find.text('Academic Press'), findsOneWidget);

      // Verify Exact Quote banner
      expect(
          find.textContaining('Practice virtue every hour.'), findsOneWidget);

      // Tap Bookmark / Save button
      final saveBtn = find.byTooltip('Save note');
      expect(saveBtn, findsOneWidget);
      await tester.tap(saveBtn);
      expect(saved, isTrue);

      // Tap Dismiss button
      final dismissBtn = find.byTooltip('Dismiss card');
      expect(dismissBtn, findsOneWidget);
      await tester.tap(dismissBtn);
      expect(dismissed, isTrue);
    });

    testWidgets('renders Critical Debate card with Counterpoint and Evidence',
        (tester) async {
      const cardItem = ReaderItem(
        id: 'card-2',
        type: 'context_card',
        cardType: 'explain',
        title: 'CRITICAL DEBATE: Marcus Aurelius Imperial Autocracy',
        body:
            'Counterpoint: Historians question whether Marcus genuinely preserved republican ideals.\nEvidence: Cassius Dio noted absolute authority remained centralized in the Princeps.',
        citations: [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextCardWidget(
              card: cardItem,
              onToggleSave: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );

      // Verify Eyebrow archetype badge
      expect(find.text('CRITICAL DEBATE'), findsOneWidget);
      expect(find.text('COUNTERPOINT'), findsOneWidget);
      expect(find.text('EVIDENCE'), findsOneWidget);
      expect(find.textContaining('Historians question whether Marcus'),
          findsOneWidget);
      expect(find.textContaining('Cassius Dio noted absolute authority'),
          findsOneWidget);
    });
  });
}
