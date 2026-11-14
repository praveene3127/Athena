import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:athena/app.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/features/reader/widgets/context_card_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Pass 1: Theme Switching & Unification Tests (ISM-01)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets(
        'Tapping theme toggle button in AthenaApp immediately switches Paper (#FBF9F5) to Charcoal (#121316), and Sepia/OLED match token colors',
        (tester) async {
      // Pump the real AthenaApp inside ProviderScope
      await tester.pumpWidget(
        const ProviderScope(
          child: AthenaApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Initial State: Paper (#FBF9F5)
      MaterialApp app = tester.widget(find.byType(MaterialApp));
      expect(app.theme?.scaffoldBackgroundColor, const Color(0xFFFBF9F5));

      // Check context tokens in initial state
      final BuildContext initialContext =
          tester.element(find.byType(AthenaApp).first);
      expect(AppTheme.bgOf(initialContext), const Color(0xFFFBF9F5));

      // Find the whole-app theme switcher icon button on LibraryScreen
      final toggleFinder = find.byWidgetPredicate((widget) {
        if (widget is Icon) {
          return widget.icon == Icons.dark_mode_outlined ||
              widget.icon == Icons.light_mode_outlined;
        }
        return false;
      });
      expect(toggleFinder, findsOneWidget);

      // Tap the theme toggle button
      await tester.tap(toggleFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 2. Switched to Dark / Charcoal (#121316)
      app = tester.widget(find.byType(MaterialApp));
      expect(app.theme?.scaffoldBackgroundColor, const Color(0xFF121316));

      final BuildContext darkContext =
          tester.element(find.byType(Scaffold).first);
      expect(AppTheme.bgOf(darkContext), const Color(0xFF121316));
      expect(AppTheme.isDark(darkContext), isTrue);

      // 3. Select Sepia (#F4ECD8)
      final element = tester.element(find.byType(Scaffold).first);
      final container = ProviderScope.containerOf(element);
      await container
          .read(athenaAppearanceProvider.notifier)
          .setAppearance(AthenaAppearance.sepia);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final BuildContext sepiaContext =
          tester.element(find.byType(Scaffold).first);
      expect(AppTheme.bgOf(sepiaContext), const Color(0xFFF4ECD8));

      // 4. Select OLED (#000000)
      await container
          .read(athenaAppearanceProvider.notifier)
          .setAppearance(AthenaAppearance.oled);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final BuildContext oledContext =
          tester.element(find.byType(Scaffold).first);
      expect(AppTheme.bgOf(oledContext), const Color(0xFF000000));
    });
  });

  group('Pass 1: Foreign Abstract & Fake Template Elimination Tests', () {
    const englishPassage =
        'The headmaster stood solemnly before the assembly of students and faculty members '
        'in the grand hall of the historic academy. For generations, traditional education '
        'emphasized disciplined study, collective integrity, and intellectual curiosity. '
        'He looked across the audience and reflected on the enduring values that had shaped '
        'the institution through decades of societal transformation and moral debate.';

    test('Strict script and language gate rejects Russian and Chinese abstracts for English passage',
        () {
      // 1. Russian abstract from Crossref/OpenAlex for the word 'Headmaster'
      const russianAbstract =
          'Статья посвящена исследованию влияния квалификации и опыта управленческих команд '
          '(директора и заместителей директора) на качество образования в общеобразовательных организациях. '
          'Проанализированы результаты государственной итоговой аттестации выпускников.';
      const russianTitle = 'Влияние управленческих команд на качество образования';

      final matchesRussian =
          LocalContextService.matchesPassageLanguageAndScript(
        passage: englishPassage,
        title: russianTitle,
        abstractText: russianAbstract,
      );
      expect(matchesRussian, isFalse,
          reason: 'Russian abstract must be rejected 100% of the time for an English passage');

      // 2. Chinese abstract
      const chineseAbstract =
          '本文基于全国各省份教育统计数据，实证分析了校长领导力对中学生学业表现的影响机制，'
          '探讨了教师教学质量的中介效应与学校资源的调节作用。';
      const chineseTitle = '校长领导力与中学教育质量的实证研究';

      final matchesChinese =
          LocalContextService.matchesPassageLanguageAndScript(
        passage: englishPassage,
        title: chineseTitle,
        abstractText: chineseAbstract,
      );
      expect(matchesChinese, isFalse,
          reason: 'Chinese abstract must be rejected 100% of the time for an English passage');

      // 3. Valid English abstract with appropriate English stopwords
      const englishAbstract =
          'This empirical study investigates the impact of secondary school headmasters and educational leadership '
          'on student academic achievement across four hundred institutions. The findings demonstrate a significant '
          'positive correlation between administrative stability, teacher retention, and examination performance.';
      const englishTitle = 'Educational Leadership and School Performance: An Empirical Evaluation';

      final matchesEnglish =
          LocalContextService.matchesPassageLanguageAndScript(
        passage: englishPassage,
        title: englishTitle,
        abstractText: englishAbstract,
      );
      expect(matchesEnglish, isTrue,
          reason: 'Authentic English peer-reviewed paper abstract must pass the gate');
    });

    test('scoreAndFilterEvidence strips foreign language results 100% of the time',
        () {
      final candidates = [
        {
          'title': 'Влияние управленческих команд на качество образования',
          'abstract':
              'Статья посвящена исследованию влияния квалификации и опыта управленческих команд '
              '(директора и заместителей директора) на качество образования в общеобразовательных организациях.',
          'publisher': 'Moscow University Press',
          'url': 'https://doi.org/10.1234/ru.edu.5678',
        },
        {
          'title':
              'Educational Leadership, Student Performance, and Integrity',
          'abstract':
              'This empirical study examines the role of school leadership and headmasters '
              'in fostering student integrity and traditional educational outcomes across multiple cohorts. '
              'The results indicate substantial gains in school climate and academic rigor.',
          'publisher': 'Journal of Educational Research',
          'url': 'https://doi.org/10.1234/jer.2024.001',
        },
      ];

      final filtered = LocalContextService.scoreAndFilterEvidence(
        candidates: candidates,
        concept: 'Headmaster',
        passage: englishPassage,
      );

      // The Russian candidate must NOT be present
      expect(filtered.length, 1);
      expect(filtered.first['publisher'], 'Journal of Educational Research');
      expect(filtered.first['title'], contains('Educational Leadership'));
    });

    test('Zero Context Cards contain fake archetype templates', () {
      final service = LocalContextService();
      const sampleExtract =
          'Headmasters across independent academies maintained traditional curriculum requirements. '
          'Records from Cambridge archives demonstrate that standard examination scores increased '
          'when disciplined mentorship was consistently implemented.';

      final archetypes = [
        'REAL-WORLD STUDY',
        'HISTORICAL BACKSTORY',
        'COUNTER-INTUITIVE FACT',
        'THE HIDDEN MECHANISM',
      ];

      for (final arch in archetypes) {
        final body = service.formatArchetypeBodyForTest(
          arch,
          'Traditional Education',
          sampleExtract,
        );

        // Verification: Fake template prefixes deleted
        expect(body,
            isNot(contains('Archival records and primary historical accounts reveal that')));
        expect(body,
            isNot(contains('Empirical investigations into')));
        expect(body,
            isNot(contains('In contrast to conventional assumptions')));
        expect(body,
            isNot(contains('Beneath the surface mechanism')));
        expect(body,
            isNot(contains('Counter-intuitive field evidence shows')));

        // Verification: Returns clean extract directly
        expect(body, sampleExtract);
      }
    });

    test('Never pick a fused or corrupted token as concept', () {
      // "Nolanintonedsolemnly" must be detected as corrupted
      expect(
          LocalContextService.isCorruptedOrFusedConcept('Nolanintonedsolemnly'),
          isTrue);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('Thisyear'), isTrue);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('hebellowed'), isTrue);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('andstudents'), isTrue);

      // Valid dictionary words and technical vocabulary must NOT be flagged
      expect(
          LocalContextService.isCorruptedOrFusedConcept('neuroplasticity'),
          isFalse);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('electromagnetism'),
          isFalse);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('Education'), isFalse);
      expect(
          LocalContextService.isCorruptedOrFusedConcept('Integrity'), isFalse);

      // Concept extraction on passage with fused token skips the fused token
      final s = LocalContextService();
      const corruptedPassage =
          'Headmaster Nolanintonedsolemnly stood before the gathering. '
          'He spoke about Educational Leadership and moral fortitude.';
      final concept = s.extractSalientConcept(corruptedPassage);
      expect(concept, isNot('Nolanintonedsolemnly'));
      expect(concept, isNot(contains('intonedsolemnly')));
    });

    test('Suffix/function-word boundary splitter splits fused tokens accurately', () {
      expect(safeSplitFusedWord('Nolanintonedsolemnly'), 'Nolan intoned solemnly');
      expect(safeSplitFusedWord('Thisyear'), 'This year');
      expect(safeSplitFusedWord('distinguishedalumni'), 'distinguished alumni');
      expect(safeSplitFusedWord('andstudents'), 'and students');
      expect(safeSplitFusedWord('hebellowed'), 'he bellowed');
      expect(safeSplitFusedWord('whatarethefourpillars'), 'what are the four pillars');

      // Valid compounds must NOT be split
      expect(safeSplitFusedWord('understanding'), 'understanding');
      expect(safeSplitFusedWord('neuroplasticity'), 'neuroplasticity');
      expect(safeSplitFusedWord('electromagnetism'), 'electromagnetism');
    });

    testWidgets('ContextCardWidget shows PASSAGE INSIGHT when support_tier is internal_extractive',
        (tester) async {
      final internalCard = ReaderItem(
        type: 'context_card',
        id: 'card-internal-1',
        title: 'Traditional Education',
        body: 'A fundamental theme woven across the early chapters of this work.',
        supportTier: 'internal_extractive',
        supportStatus: 'internal_extractive',
        citations: const [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContextCardWidget(
              card: internalCard,
              themeId: 'paper',
              onToggleSave: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Top badge must say PASSAGE INSIGHT, never HISTORICAL BACKSTORY or REAL-WORLD STUDY
      expect(find.text('PASSAGE INSIGHT'), findsOneWidget);
      expect(find.text('HISTORICAL BACKSTORY'), findsNothing);
      expect(find.text('REAL-WORLD STUDY'), findsNothing);
      expect(find.text('BOOK CROSS-REFERENCE / CONCEPT NOTE'), findsOneWidget);
    });
  });
}
