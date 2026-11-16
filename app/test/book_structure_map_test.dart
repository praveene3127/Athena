import 'package:flutter_test/flutter_test.dart';
import 'package:athena/models/section_role.dart';
import 'package:athena/models/document.dart';
import 'package:athena/services/ingestion_pipeline.dart';

void main() {
  group('Book Structure Map & SectionRole Immunity (Batch 1)', () {
    test('1. SectionRole.fromString substring false positive immunity (A7)', () {
      // These titles contain 'ack', 'part', 'intro' as substrings, but are NOT those section roles:
      expect(SectionRole.fromString('Back to the Land'), equals(SectionRole.unknown));
      expect(SectionRole.fromString('Attack Surface'), equals(SectionRole.unknown));
      expect(SectionRole.fromString('Tracking the Future'), equals(SectionRole.unknown));
      expect(SectionRole.fromString('Counterpart'), equals(SectionRole.unknown));
      expect(SectionRole.fromString('Apart'), equals(SectionRole.unknown));
      expect(SectionRole.fromString('Introspection'), equals(SectionRole.unknown));

      // Positive assertions
      expect(SectionRole.fromString('Introduction'), equals(SectionRole.introduction));
      expect(SectionRole.fromString('Intro to Focus'), equals(SectionRole.introduction));
      expect(SectionRole.fromString('Acknowledgments'), equals(SectionRole.acknowledgments));
      expect(SectionRole.fromString('Special Thanks'), equals(SectionRole.acknowledgments));
      expect(SectionRole.fromString('Part 1: The Principle'), equals(SectionRole.part));
      expect(SectionRole.fromString('Chapter 2: The Mind'), equals(SectionRole.chapter));
      expect(SectionRole.fromString('Index'), equals(SectionRole.bookIndex));
      expect(SectionRole.fromString('book_index'), equals(SectionRole.bookIndex));
      expect(SectionRole.fromString('Notes'), equals(SectionRole.notes));
    });

    test('2. TocDetector rejects Index pages and back-25% non-TOC pages (A6, B03)', () {
      final indexText = 'Index\nattention, 5, 9, 12\nfocus, 3, 18, 22\nmeaning, 7, 11';
      final res = TocDetector.analyzePage(
        lines: const [],
        bodyRight: 500,
        rawPageText: indexText,
        pageNum: 12,
        totalPages: 12,
      );
      expect(res.isToc, isFalse);
      expect(res.entries, isEmpty);

      // Back 25% page without Contents header
      final backPageText = 'Chapter 2 Continuation\nSome narrative prose text here ending in 15';
      final backRes = TocDetector.analyzePage(
        lines: const [],
        bodyRight: 500,
        rawPageText: backPageText,
        pageNum: 10,
        totalPages: 12,
      );
      expect(backRes.isToc, isFalse);
    });

    test('3. ReaderData parses structure map and chunk page ranges (B2, B6)', () {
      final json = {
        'document': {
          'id': 'doc_123',
          'title': 'The Art of Attention',
          'status': 'ready',
          'page_count': 12,
        },
        'items': [
          {
            'type': 'reading_chunk',
            'id': 'chunk_1',
            'sequence': 1,
            'text': 'Introduction prose text',
            'section_title': 'Introduction',
            'section_role': 'introduction',
            'page_start': 5,
            'page_end': 5,
          },
          {
            'type': 'reading_chunk',
            'id': 'chunk_2',
            'sequence': 2,
            'text': 'Chapter 1 prose text',
            'section_title': 'Chapter 1: The Problem',
            'section_role': 'chapter',
            'page_start': 6,
            'page_end': 7,
          },
          {
            'type': 'reading_chunk',
            'id': 'chunk_3',
            'sequence': 3,
            'text': 'Acknowledgments text',
            'section_title': 'Acknowledgments',
            'section_role': 'acknowledgments',
            'page_start': 10,
            'page_end': 10,
          },
        ],
        'structure': {
          'digest': '1 chapter · Introduction & Acknowledgments',
          'zones': [
            {'zone': 'front', 'from_seq': 1, 'to_seq': 1, 'label': 'Front Matter'},
            {'zone': 'body', 'from_seq': 2, 'to_seq': 2, 'label': 'Body'},
            {'zone': 'back', 'from_seq': 3, 'to_seq': 3, 'label': 'Back Matter'},
          ],
          'sections': [
            {
              'role': 'introduction',
              'zone': 'front',
              'title': 'Introduction',
              'from_seq': 1,
              'to_seq': 1,
              'in_feed': true,
            },
            {
              'role': 'chapter',
              'zone': 'body',
              'title': 'Chapter 1: The Problem',
              'from_seq': 2,
              'to_seq': 2,
              'in_feed': true,
            },
            {
              'role': 'acknowledgments',
              'zone': 'back',
              'title': 'Acknowledgments',
              'from_seq': 3,
              'to_seq': 3,
              'in_feed': false,
            },
          ],
        },
      };

      final readerData = ReaderData.fromJson(json);
      expect(readerData.items.length, equals(3));
      expect(readerData.items[0].sectionRole, equals('introduction'));
      expect(readerData.items[0].pageStart, equals(5));
      expect(readerData.items[0].pageEnd, equals(5));
      expect(readerData.items[1].sectionRole, equals('chapter'));
      expect(readerData.items[1].pageStart, equals(6));
      expect(readerData.items[1].pageEnd, equals(7));

      expect(readerData.structure, isNotNull);
      final structure = readerData.structure!;
      expect(structure['digest'], contains('Introduction & Acknowledgments'));
      final zones = structure['zones'] as List;
      expect(zones.length, equals(3));
      final sections = structure['sections'] as List;
      expect(sections.length, equals(3));
      expect(sections[0]['in_feed'], isTrue);
      expect(sections[1]['in_feed'], isTrue);
      expect(sections[2]['in_feed'], isFalse); // Acknowledgments preserved out of feed
    });
  });
}
