import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Reading Psychology & High-Signal Chunk Selection Tests', () {
    final service = LocalContextService();

    test('rejection of short or transitional chunks (< 30 words)', () {
      final shortChunk = {
        'id': 'c-short-1',
        'raw_text': 'He paused and turned back to the window, watching the rain.',
      };
      final transitionalChunk = {
        'id': 'c-short-2',
        'raw_text': 'Chapter Four began the following Tuesday morning in quiet silence.',
      };

      final score1 = service.scoreChunkTension(shortChunk);
      final score2 = service.scoreChunkTension(transitionalChunk);

      expect(score1, equals(-100),
          reason: 'Chunks under 30 words must be rejected with -100');
      expect(score2, equals(-100),
          reason: 'Transitional sentences under 30 words must be rejected with -100');
    });

    test('high tension scoring on passages with conflict, mystery, and vocabulary', () {
      final tensionChunk = {
        'id': 'c-tension-1',
        'raw_text':
            'Why did the inner council shroud the truth in complete silence? The fear of betrayal and the strange illusion of absolute power had driven them into an impossible corner, where every spoken question became a matter of life or death before the ancient law.',
      };

      final score = service.scoreChunkTension(tensionChunk);
      expect(score, greaterThan(25),
          reason: 'Passages with tension keywords and 35-75 words should score highly');
    });

    test('windowed selection (4-6 chunks) chooses the highest tension passage', () async {
      final chunks = [
        {
          'id': 'c-1',
          'sequence': 1,
          'raw_text': 'The rain fell softly against the carriage window as they drove through town.', // < 30 words (-100)
        },
        {
          'id': 'c-2',
          'sequence': 2,
          'raw_text':
              'In the shadows of the old library, the secret was whispered from master to apprentice with growing dread. The truth carried a heavy burden, for knowledge of this power had led many into ruin and silent despair.',
        },
        {
          'id': 'c-3',
          'sequence': 3,
          'raw_text': 'He reached for the ledger and opened the leather cover slowly.', // < 30 words (-100)
        },
        {
          'id': 'c-4',
          'sequence': 4,
          'raw_text':
              'Every morning the clerks arrived at dawn to prepare the correspondence for the day ahead, keeping records in neat ink.',
        },
        {
          'id': 'c-5',
          'sequence': 5,
          'raw_text': 'A bell rang in the courtyard below.', // < 30 words (-100)
        },
      ];

      final cards = await service.buildCards('doc-101', chunks);
      expect(cards.isNotEmpty, isTrue);

      // The highest tension chunk in window 1-5 is c-2 (secret, truth, dread, power, despair)
      final firstCard = cards.first;
      expect(firstCard['source_chunk_id'], equals('c-2'),
          reason: 'Windowed selection must pick the chunk with highest narrative/conceptual tension');
    });
  });

  group('Prohibition of Banned Filler & Reading Psychology Mandates', () {
    final service = LocalContextService();

    final testChunk = {
      'id': 'c-anchor-1',
      'raw_text':
          'Beneath the surface of Athenian politics lay a profound paradox regarding democratic autonomy and civic responsibility. Citizens wrestled with the moral question of whether individual freedom could coexist peacefully with collective duty under the rule of law.',
    };

    final bannedPhrases = [
      'In this passage',
      'This passage explores',
      'The text demonstrates',
      'Structural synthesis',
      'Empirical observation indicates',
      'In documented investigations into',
      'Key takeaway',
      '||REVEAL||',
      'Question:',
      'Answer:',
    ];

    test('all 4 generated archetypes are free of banned filler phrases', () {
      for (int slot = 0; slot < 4; slot++) {
        final card = service.generateSpeculativeDraftCard('doc-test', testChunk, slot);
        final body = card['body'] as String;
        final title = card['title'] as String;

        for (final banned in bannedPhrases) {
          expect(body.contains(banned), isFalse,
              reason: 'Card body must NEVER contain banned filler phrase: "$banned"');
          expect(title.contains(banned), isFalse,
              reason: 'Card title must NEVER contain banned filler phrase: "$banned"');
        }
      }
    });

    test('generated cards follow the 3 Psychological Laws of Reading Immersion', () {
      for (int slot = 0; slot < 4; slot++) {
        final card = service.generateSpeculativeDraftCard('doc-test', testChunk, slot);
        final body = card['body'] as String;

        // Law 1: Deepen the scene (must contain exact anchor quote)
        final exactQuote = card['exact_quote'] as String;
        expect(exactQuote.isNotEmpty, isTrue);
        expect(testChunk['raw_text']!.contains(exactQuote), isTrue,
            reason: 'Card must anchor to authentic substring of passage');

        // Law 2: Vivid, conversational voice (no robotic or passive bureaucratic framing)
        expect(body.startsWith('In this passage'), isFalse);
        expect(body.startsWith('The author is trying to say'), isFalse);

        // Law 3: Forward-pull closing line (pulls reader back into next section of text)
        final forwardPulls = [
          'what is about to happen next',
          'as the scene unfolds',
          'Watch closely how this hidden lineage surfaces',
          'ultimate test',
        ];
        final hasForwardPull = forwardPulls.any((phrase) => body.contains(phrase));
        expect(hasForwardPull, isTrue,
            reason: 'Card must close with forward-pull line directing reader back to narrative');
      }
    });
  });

  group('ContextCardWidget 3 Visual Variants at 390x844 Viewport', () {
    void setPhoneViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
    }

    testWidgets('Variant A (Story Behind It / Warm Editorial Aside) renders with zero overflow',
        (tester) async {
      setPhoneViewport(tester);
      addTearDown(() => tester.view.resetPhysicalSize());

      final itemA = ReaderItem(
        type: 'context_card',
        id: 'card-a',
        title: 'REAL-WORLD STUDY: Autonomic Arousal in Solitary Reading',
        body:
            'When measured in controlled clinical trials, the physiological shift behind silent reading drops heart rate variability significantly. Notice how this tension quietly reshapes what happens next.',
        exactQuote: 'silent reading drops heart rate',
        sequence: 0,
        cardType: 'empirical_study',
        citations: [
          {'publisher': 'Journal of Cognitive Science (2023)', 'url': 'https://doi.org/10.1016/j.cogsci.2023.01'}
        ],
      );

      expect(ContextCardWidget.resolveVariant(itemA, itemA.body!),
          equals(CardLayoutVariant.storyBehindIt));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ContextCardWidget(
                card: itemA,
                onToggleSave: () {},
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('REAL-WORLD STUDY'), findsOneWidget);
      expect(find.textContaining('Autonomic Arousal in Solitary Reading'), findsOneWidget);
      expect(find.textContaining('Notice how this tension quietly reshapes'), findsOneWidget);
      expect(find.textContaining('SOURCE: JOURNAL OF COGNITIVE SCIENCE'), findsOneWidget);
    });

    testWidgets('Variant B (Psychological Lens / Pull-Quote with Left Accent) renders with zero overflow',
        (tester) async {
      setPhoneViewport(tester);
      addTearDown(() => tester.view.resetPhysicalSize());

      final itemB = ReaderItem(
        type: 'context_card',
        id: 'card-b',
        title: 'PSYCHOLOGICAL LENS: The Illusion of Moral Superiority',
        body:
            'Beneath the defensive posture lies a well-documented human bias: we judge ourselves by our motives, but others by their actions. Keep this contrarian dynamic in mind as the scene unfolds.',
        exactQuote: 'we judge ourselves by our motives',
        sequence: 1,
        cardType: 'philosophy_paradox',
        citations: [
          {'publisher': 'Psychological Review', 'url': 'https://doi.org/10.1037/rev0000214'}
        ],
      );

      expect(ContextCardWidget.resolveVariant(itemB, itemB.body!),
          equals(CardLayoutVariant.psychologicalLens));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ContextCardWidget(
                card: itemB,
                onToggleSave: () {},
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('THE HIDDEN MECHANISM'), findsOneWidget);
      expect(find.textContaining('The Illusion of Moral Superiority'), findsOneWidget);
      expect(find.textContaining('Beneath the defensive posture lies'), findsOneWidget);
      expect(find.textContaining('SOURCE: PSYCHOLOGICAL REVIEW'), findsOneWidget);
    });

    testWidgets('Variant C (The Sharp Detail / Compact Margin Note) renders with zero overflow',
        (tester) async {
      setPhoneViewport(tester);
      addTearDown(() => tester.view.resetPhysicalSize());

      final itemC = ReaderItem(
        type: 'context_card',
        id: 'card-c',
        title: 'SHARP DETAIL: Etymological Origin of Malice',
        body: 'From the Latin malus, meaning bad or ill-intentioned. Pay close attention to what follows.',
        exactQuote: 'Latin malus',
        sequence: 2,
        cardType: 'historical_case',
        citations: [
          {'publisher': 'Oxford Classical Dictionary', 'url': 'https://doi.org/10.1093/ocd'}
        ],
      );

      expect(ContextCardWidget.resolveVariant(itemC, itemC.body!),
          equals(CardLayoutVariant.sharpDetail));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ContextCardWidget(
                card: itemC,
                onToggleSave: () {},
                onDismiss: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('HISTORICAL BACKSTORY'), findsOneWidget);
      expect(find.textContaining('Etymological Origin of Malice'), findsOneWidget);
      expect(find.textContaining('From the Latin malus'), findsOneWidget);
      expect(find.textContaining('SOURCE: OXFORD CLASSICAL DICTIONARY'), findsOneWidget);
    });
  });
}
