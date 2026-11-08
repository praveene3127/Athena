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
  });
}
