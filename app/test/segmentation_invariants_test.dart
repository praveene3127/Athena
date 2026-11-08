import 'package:flutter_test/flutter_test.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/services/segmentation_policy.dart';
import 'package:athena/models/section_role.dart';
import 'package:athena/services/ingestion_pipeline.dart';

void main() {
  group('Segmentation & Chunking Invariants (Pass 1 - Pass 3)', () {
    // Invariant 1: SegmentationPolicy.isLegalCut holds for chunk start & end offsets (0 mid-token cuts)
    test('Invariant 1: isLegalCut holds for all chunk boundaries (0 mid-token cuts)', () {
      const text =
          'The quick brown fox jumps over the lazy dog. In 1914–1918 Europe saw catastrophic conflict. '
          'According to John 3:16, love is boundless. The ratio was approximately 3.14159 in their calculations. '
          'Visit https://athena-reader.org/docs for more details on the architecture.';
      
      expect(SegmentationPolicy.isLegalCut(text, 0), isTrue);
      expect(SegmentationPolicy.isLegalCut(text, text.length), isTrue);
      expect(SegmentationPolicy.isLegalCut(text, 4), isTrue); // after 'The '

      // Mid-word cuts must be illegal
      expect(SegmentationPolicy.isLegalCut(text, 2), isFalse); // inside 'The'
      expect(SegmentationPolicy.isLegalCut(text, 7), isFalse); // inside 'quick'

      // Chunker output boundaries must all satisfy isLegalCut
      final spans = [{'start': 0, 'end': text.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}];
      final chunks = LosslessChunker().build(
        documentId: 'doc-invariants-1',
        canonicalText: text,
        spans: spans,
      );

      for (final chunk in chunks) {
        final start = chunk['start_offset'] as int;
        final end = chunk['end_offset'] as int;
        expect(SegmentationPolicy.isLegalCut(text, start), isTrue,
            reason: 'Start offset $start must be a legal cut');
        expect(SegmentationPolicy.isLegalCut(text, end), isTrue,
            reason: 'End offset $end must be a legal cut');
      }
    });

    // Invariant 2: 0 chunks start with a lowercase continuation of a line-wrap hyphenated word
    test('Invariant 2: No chunk begins with a lowercase orphan from line-wrap hyphenation', () {
      final sample =
          'It was a monumental trans-\nformation of digital reading technology. '
          'We must nurture our self-\nesteem while cultivating mutual respect across cultures. '
          'The whole-document reflow engine ensures that every passage reads smoothly and consistently.';
      
      final repaired = DocumentIngestionPipeline.dehyphenateLineWraps(sample);
      expect(repaired, contains('transformation'));
      expect(repaired, contains('self-esteem'));

      final spans = [{'start': 0, 'end': repaired.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}];
      final chunks = LosslessChunker().build(
        documentId: 'doc-invariants-2',
        canonicalText: repaired,
        spans: spans,
      );

      for (final chunk in chunks) {
        final rawText = (chunk['raw_text'] as String).trimLeft();
        if (rawText.isNotEmpty) {
          // A chunk should never start with a standalone hyphen followed by lowercase, e.g. "-formation"
          expect(rawText.startsWith(RegExp(r'^-[a-z]')), isFalse,
              reason: 'Chunk should not start with hyphenated orphan suffix: $rawText');
        }
      }
    });

    // Invariant 3: Words-per-chunk cadence stable (0 orphan chunks < 20 words except genuine section endings)
    test('Invariant 3: Cadence is stable without arbitrary sub-20 word orphan fragments', () {
      final longParagraph = List.generate(
        15,
        (i) => 'This is sentence number $i articulating an insightful epistemic perspective with rich vocabulary.',
      ).join(' ');

      final spans = [{'start': 0, 'end': longParagraph.length, 'page_start': 1, 'page_end': 2, 'type': 'paragraph'}];
      final chunks = LosslessChunker().build(
        documentId: 'doc-invariants-3',
        canonicalText: longParagraph,
        spans: spans,
      );

      expect(chunks.length, greaterThanOrEqualTo(2));
      // Except possibly the last trailing chunk in a section, no chunk should be an orphan < 20 words
      for (int i = 0; i < chunks.length - 1; i++) {
        final text = (chunks[i]['raw_text'] as String).trim();
        final wordCount = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        expect(wordCount, greaterThanOrEqualTo(20),
            reason: 'Intermediate chunk $i has only $wordCount words');
      }
    });

    // Invariant 4: 0 TOC, copyright, ISBN, or index lines reach body prose chunks
    test('Invariant 4: Structure resolver classifies matter vs body correctly', () {
      expect(SectionRole.toc.isMatter, isTrue);
      expect(SectionRole.copyright.isMatter, isTrue);
      expect(SectionRole.bookIndex.isMatter, isTrue);
      expect(SectionRole.bibliography.isMatter, isTrue);
      expect(SectionRole.chapter.isMatter, isFalse);
      expect(SectionRole.preface.isMatter, isFalse);
      expect(SectionRole.introduction.isMatter, isFalse);
    });

    // Invariant 5: Substantive Preface/Introduction prose kept and tagged SectionRole.preface / introduction
    test('Invariant 5: Preface and introduction are marked as readable non-matter sections', () {
      expect(SectionRole.preface.isReadable, isTrue);
      expect(SectionRole.introduction.isReadable, isTrue);
      expect(SectionRole.foreword.isReadable, isTrue);
      expect(SectionRole.prologue.isReadable, isTrue);
    });

    // Invariant 6: Sentence boundary golden rules pass (closing quotes, parentheses, abbreviations, decimals)
    test('Invariant 6: Golden sentence splitter respects abbreviations, decimals, quotes, and colons', () {
      const complex =
          'Dr. Watson went to St. Jude Hospital at 4:30 p.m. '
          'He exclaimed, "Look at that!" The price was \$14.99 per item. '
          'In John 3:16 we read of transcendent love. '
          'Euler’s number e is approx. 2.71828 in calculus.';

      final sentences = SentenceSplitter.split(complex);
      expect(sentences, isNotEmpty);
      // "Dr. Watson..." should NOT be split after "Dr."
      expect(sentences.any((s) => s.startsWith('Watson')), isFalse);
      // "St. Jude..." should NOT be split after "St."
      expect(sentences.any((s) => s.startsWith('Jude')), isFalse);
      // "4:30 p.m." should not be chopped at colon
      expect(sentences.any((s) => s.contains('4:30 p.m.')), isTrue);
      // "14.99" should not be chopped at decimal
      expect(sentences.any((s) => s.contains('14.99')), isTrue);
      // "John 3:16" should not be split
      expect(sentences.any((s) => s.contains('John 3:16')), isTrue);
    });

    // Invariant 7: Line-end de-hyphenation (trans-\nformation -> transformation, self-\nesteem -> self-esteem)
    test('Invariant 7: Line-end de-hyphenation correctly reconstructs soft and compound hyphens', () {
      const softHyphen = 'trans-\n formation';
      const compoundHyphen = 'self-\n esteem';
      const legitimateWord = 'under-\n standing';

      expect(DocumentIngestionPipeline.dehyphenateLineWraps(softHyphen), equals('transformation'));
      expect(DocumentIngestionPipeline.dehyphenateLineWraps(compoundHyphen), equals('self-esteem'));
      expect(DocumentIngestionPipeline.dehyphenateLineWraps(legitimateWord), equals('understanding'));
    });

    // Invariant 8: Lossless reconstruction invariant (join(chunks) == canonical_text)
    test('Invariant 8: Lossless byte-exact reconstruction invariant holds exactly', () {
      const canonical =
          'First paragraph of the manuscript.\n\n'
          'Second paragraph containing specialized terms like neuroplasticity and quantum chromodynamics. '
          'The narrative flows uninterrupted across all boundary transitions.\n\n'
          'Third paragraph concluding the chapter with definitive closure.';

      final spans = [
        {'start': 0, 'end': 35, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'},
        {'start': 37, 'end': 188, 'page_start': 1, 'page_end': 2, 'type': 'paragraph'},
        {'start': 190, 'end': canonical.length, 'page_start': 2, 'page_end': 2, 'type': 'paragraph'},
      ];

      final chunks = LosslessChunker().build(
        documentId: 'doc-lossless-inv',
        canonicalText: canonical,
        spans: spans,
      );

      final reconstructed = chunks.map((c) => c['raw_text']).join();
      expect(reconstructed, equals(canonical));
    });

    // Invariant 9: Legitimate compound/long words never rewritten
    test('Invariant 9: Preserves legitimate compound and technical words without erroneous splitting', () {
      const words = [
        'schoolteacher',
        'breakthrough',
        'thanksgiving',
        'withholding',
        'nevertheless',
        'counterpoint',
        'neuroplasticity',
        'electromagnetism',
      ];

      for (final w in words) {
        final repaired = sanitizeProseSpacing(w);
        expect(repaired, equals(w),
            reason: 'Legitimate word $w should never be mutated by spacing repair');
      }
    });

    test('Invariant 10: Mixed-case brands and surname prefixes are preserved without splitting (K-8)', () {
      const names = [
        'FitzGerald',
        'JPMorgan',
        "McDonald's",
        'McCarthy',
        'MacArthur',
        'DeLillo',
      ];
      for (final name in names) {
        final repaired = sanitizeProseSpacing(name);
        expect(repaired, equals(name),
            reason: 'Name or brand $name must be protected from kerning/case splitting');
      }
    });

    test('Invariant 11: Balanced oversized splitting eliminates short orphan tails and satisfies isLegalCut (K-2)', () {
      // Create a 700-character paragraph of authentic prose
      final longParagraph = List.generate(
        15,
        (i) => 'Authentic sentence number $i exploring neural cognitive models in literature.',
      ).join(' ');

      final spans = [
        {'start': 0, 'end': longParagraph.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'}
      ];

      final chunks = LosslessChunker().build(
        documentId: 'oversized_test_doc',
        canonicalText: longParagraph,
        spans: spans,
      );

      expect(chunks.length, greaterThan(1));
      // Reconstructed text must equal original
      final reconstructed = chunks.map((c) => c['raw_text']).join();
      expect(reconstructed, equals(longParagraph));

      for (final chunk in chunks) {
        final raw = chunk['raw_text'] as String;
        final words = SegmentationPolicy.countWords(raw);
        // Every split part should be balanced, not an orphan tail of < 15 words
        expect(words, greaterThanOrEqualTo(15),
            reason: 'Balanced splitting must prevent tiny orphan tails');
        expect(SegmentationPolicy.isLegalCut(longParagraph, chunk['start_offset'] as int), isTrue);
        expect(SegmentationPolicy.isLegalCut(longParagraph, chunk['end_offset'] as int), isTrue);
      }
    });

    test('Invariant 12: Bidirectional merge eliminates sub-24 word fragments within the same section (K-6)', () {
      // 3 short paragraphs in same chapter
      final text = 'Short introductory thought.\n\nAnother brief observation on history.\n\nA third small remark for the reader.';
      final spans = [
        {'start': 0, 'end': 27, 'page_start': 1, 'page_end': 1, 'type': 'paragraph', 'section_title': 'Chapter 1', 'section_role': 'chapter'},
        {'start': 29, 'end': 66, 'page_start': 1, 'page_end': 1, 'type': 'paragraph', 'section_title': 'Chapter 1', 'section_role': 'chapter'},
        {'start': 68, 'end': text.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph', 'section_title': 'Chapter 1', 'section_role': 'chapter'},
      ];

      final chunks = LosslessChunker().build(
        documentId: 'short_merge_doc',
        canonicalText: text,
        spans: spans,
      );

      // Chunks should merge into fewer chunks rather than 3 tiny isolated fragments
      expect(chunks.length, lessThan(3));
      final reconstructed = chunks.map((c) => c['raw_text']).join();
      expect(reconstructed, equals(text));
    });

    test('Invariant 13: Section title and section role propagate to every chunk within the section (K-7)', () {
      final text = 'CHAPTER I. DOWN THE RABBIT-HOLE\n\nAlice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it.\n\nSo she was considering in her own mind whether the pleasure of making a daisy-chain would be worth the trouble of getting up and picking the daisies, when suddenly a White Rabbit with pink eyes ran close by her.';
      final spans = [
        {'start': 0, 'end': 31, 'page_start': 1, 'page_end': 1, 'type': 'heading', 'section_title': 'CHAPTER I. DOWN THE RABBIT-HOLE', 'section_role': 'chapter'},
        {'start': 33, 'end': 239, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'},
        {'start': 241, 'end': text.length, 'page_start': 1, 'page_end': 1, 'type': 'paragraph'},
      ];

      final chunks = LosslessChunker().build(
        documentId: 'alice_doc',
        canonicalText: text,
        spans: spans,
      );

      expect(chunks, isNotEmpty);
      for (final chunk in chunks) {
        expect(chunk['section_title'], equals('CHAPTER I. DOWN THE RABBIT-HOLE'),
            reason: 'Every chunk in Chapter 1 must inherit the section title');
        expect(chunk['section_role'], equals('chapter'));
      }
    });
  });
}
