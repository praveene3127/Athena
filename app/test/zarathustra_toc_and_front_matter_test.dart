import 'package:flutter_test/flutter_test.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/services/local_context_service.dart';

void main() {
  group('Pass A: Nietzsche Zarathustra TOC, Front Matter & Card Coherence', () {
    test('1. Title letter-spacing normalizer and ALL-CAPS de-fusing', () {
      // Letter-spaced title collapsing
      final title1 = sanitizeProseSpacingWithAudit('Z A R A T H U S T R A');
      expect(title1.text, equals('ZARATHUSTRA'));

      final title2 = sanitizeProseSpacingWithAudit('C O N T E N T S');
      expect(title2.text, equals('CONTENTS'));

      // ALL-CAPS academic fused word segmentation
      final defused = safeSplitFusedWord('NOTESOFTHESEMINAR');
      expect(defused, equals('NOTES OF THE SEMINAR'));
    });

    test('2. OCR-corrupted Roman & Arabic numerals in parseTocPageToken', () {
      // Roman numerals (canonical and OCR noise)
      final ix = TocDetector.parseTocPageToken('IX');
      expect(ix, isNotNull);
      expect(ix!.isRoman, isTrue);
      expect(ix.pageNumber, equals(9));

      final xxii = TocDetector.parseTocPageToken('XXll');
      expect(xxii, isNotNull);
      expect(xxii!.isRoman, isTrue);
      expect(xxii.pageNumber, equals(22));

      final xxiii = TocDetector.parseTocPageToken('XXlll');
      expect(xxiii, isNotNull);
      expect(xxiii!.isRoman, isTrue);
      expect(xxiii.pageNumber, equals(23));

      final xxiv = TocDetector.parseTocPageToken("XXI'");
      expect(xxiv, isNotNull);
      expect(xxiv!.isRoman, isTrue);
      expect(xxiv.pageNumber, equals(24));

      // Arabic numerals
      final p3 = TocDetector.parseTocPageToken('3');
      expect(p3, isNotNull);
      expect(p3!.isRoman, isFalse);
      expect(p3.pageNumber, equals(3));

      // Corrupted Arabic digits in TOC context
      final p38 = TocDetector.parseTocPageToken(';)8', hasContentsHeader: true);
      expect(p38, isNotNull);
      expect(p38!.isRoman, isFalse);
      expect(p38.pageNumber, equals(38));

      final p56 = TocDetector.parseTocPageToken('sG', hasContentsHeader: true);
      expect(p56, isNotNull);
      expect(p56!.isRoman, isFalse);
      expect(p56.pageNumber, equals(56));
    });

    test('3. OCR TOC title cleanup (cleanTocTitle)', () {
      expect(TocDetector.cleanTocTitle("INTRODUC'riO!\\"), equals('Introduction'));
      expect(TocDetector.cleanTocTitle('ACKNOWLEDGMENTS'), equals('Acknowledgments'));
      expect(TocDetector.cleanTocTitle('A NOTE ON THE TEXT'), equals('A Note on the Text'));
      expect(TocDetector.cleanTocTitle("ABBREVIATIOI'\\S"), equals('Abbreviations'));
      expect(TocDetector.cleanTocTitle('r6May1934'), equals('16 May 1934'));
    });

    test('4. Full Page 6 TOC Detection and Dual-Regime Monotonicity', () {
      final lines = <LineFragment>[
        LineFragment(
          text: 'CONTENTS',
          left: 100,
          right: 200,
          top: 50,
          bottom: 65,
          fontSize: 14,
        ),
        LineFragment(
          text: "INTRODUC'riO!\\    IX",
          left: 50,
          right: 350,
          top: 100,
          bottom: 112,
          fontSize: 11,
        ),
        LineFragment(
          text: 'ACKNOWLEDGMENTS    XXll',
          left: 50,
          right: 350,
          top: 120,
          bottom: 132,
          fontSize: 11,
        ),
        LineFragment(
          text: 'A NOTE ON THE TEXT    XXlll',
          left: 50,
          right: 350,
          top: 140,
          bottom: 152,
          fontSize: 11,
        ),
        LineFragment(
          text: 'I. 2 May 1934    3',
          left: 50,
          right: 350,
          top: 180,
          bottom: 192,
          fontSize: 11,
        ),
        LineFragment(
          text: 'II. 9 May 1934    21',
          left: 50,
          right: 350,
          top: 200,
          bottom: 212,
          fontSize: 11,
        ),
        LineFragment(
          text: 'III. 16 May 1934    38',
          left: 50,
          right: 350,
          top: 220,
          bottom: 232,
          fontSize: 11,
        ),
        LineFragment(
          text: 'IV. 23 May 1934    56',
          left: 50,
          right: 350,
          top: 240,
          bottom: 252,
          fontSize: 11,
        ),
      ];

      final rawPageText = lines.map((l) => l.text).join('\n');
      final result = TocDetector.analyzePage(
        lines: lines,
        bodyRight: 350.0,
        rawPageText: rawPageText,
      );

      expect(result.isToc, isTrue);
      expect(result.entries.length, greaterThanOrEqualTo(7));

      // Verify entries contain both Roman front-matter and Arabic chapter entries
      final titles = result.entries.map((e) => e.title).toList();
      expect(titles.any((t) => t.contains('Introduction')), isTrue);
      expect(titles.any((t) => t.contains('Acknowledgments')), isTrue);
      expect(titles.any((t) => t.contains('Note on the Text')), isTrue);
      expect(titles.any((t) => t.contains('2 May 1934')), isTrue);
      expect(titles.any((t) => t.contains('23 May 1934')), isTrue);
    });

    test('5. Non-prose matter gate classifies Page 2 as matter (isMatter == true)', () {
      final page2Lines = <LineFragment>[
        LineFragment(
          text: 'BOLLING Er\\ SERIES XCIX',
          left: 50,
          right: 300,
          top: 50,
          bottom: 65,
        ),
        LineFragment(
          text: '+ This p ag e intentionally left blank',
          left: 50,
          right: 300,
          top: 100,
          bottom: 115,
        ),
        LineFragment(
          text: "NIETZSCHE'S ZARATHUSTRA",
          left: 50,
          right: 300,
          top: 150,
          bottom: 165,
        ),
        LineFragment(
          text: 'NOTESOFTHESEMINAR',
          left: 50,
          right: 300,
          top: 200,
          bottom: 215,
        ),
      ];
      final page2RawText = page2Lines.map((l) => l.text).join('\n');

      final roles = StructureResolver.smoothRolesForWindow(
        startPage: 1,
        endPage: 2,
        totalPages: 1613,
        pageLinesMap: {1: [], 2: page2Lines},
        pageRawTextMap: {1: '', 2: page2RawText},
        bookmarks: {},
        tocPages: {},
        explicitHeadingMap: {},
      );

      expect(roles.length, equals(2));
      final page2Role = roles[1];
      expect(page2Role.isMatter, isTrue,
          reason: 'Page 2 contains publisher imprint and blank notices with 0 prose sentences');
    });

    test('6. LocalContextService strict eligibility gate & concept rejection', () {
      final contextService = LocalContextService();

      // "TEXT XXlll" must never be accepted as a salient concept
      expect(LocalContextService.isCorruptedOrFusedConcept('TEXT XXlll'), isTrue);
      expect(LocalContextService.isCorruptedOrFusedConcept('XXIII'), isTrue);
      expect(LocalContextService.isCorruptedOrFusedConcept('XXlll'), isTrue);

      final extracted = contextService.extractSalientConcept('A NOTE ON THE TEXT XXlll');
      expect(extracted, isNull,
          reason: 'Structural TOC header with Roman numeral must yield no concept');

      // Chunks marked with role = toc or title = CONTENTS must be ineligible for cards
      final tocChunk = {
        'document_id': 'doc-zarathustra-test',
        'sequence': 2,
        'page_start': 6,
        'page_end': 6,
        'section_title': 'CONTENTS',
        'section_role': 'toc',
        'raw_text': "CONTENTS\nINTRODUC'riO!\\ IX\nACKNOWLEDGMENTS XXll\nA NOTE ON THE TEXT XXlll",
      };

      expect(contextService.isChunkEligibleForCard(tocChunk), isFalse);
    });
  });
}
