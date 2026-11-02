import 'package:flutter_test/flutter_test.dart';
import 'package:athena/services/lossless_chunker.dart';

void main() {
  test('chunks reconstruct every character in source order', () {
    final paragraphs = List.generate(
      42,
      (i) =>
          'Section ${i + 1}. “Café” preserves every symbol, page label, and character. '
          'This sentence carries a little more context so boundaries remain meaningful. '
          'The reading feed should keep each passage complete and ordered.',
    );
    final source = paragraphs.join('\n\n');
    final spans = [
      {
        'start': 0,
        'end': source.length,
        'page_start': 2,
        'page_end': 7,
        'type': 'paragraph'
      },
    ];

    final chunks = LosslessChunker().build(
      documentId: 'test-document',
      canonicalText: source,
      spans: spans,
    );

    expect(chunks, isNotEmpty);
    expect(chunks.map((chunk) => chunk['raw_text']).join(), source);
    expect(chunks.map((chunk) => chunk['sequence']),
        List<int>.generate(chunks.length, (index) => index + 1));
    expect(chunks.every((chunk) => (chunk['checksum'] as String).length == 64),
        isTrue);
    expect(
        chunks.every((chunk) =>
            (chunk['start_offset']! as int) < (chunk['end_offset']! as int)),
        isTrue);
  });

  test('sanitizeProseSpacing restores spacing across punctuation, quotes, and camelCase', () {
    const rawFuesd = 'candle.HeadmasterGaleNolan,ahusky boy who carried banners.';
    final sanitized = sanitizeProseSpacing(rawFuesd);
    expect(sanitized, 'candle. Headmaster Gale Nolan, ahusky boy who carried banners.');

    const tocFused = 'CONTENTSCover TitlePage Chapter1 Chapter2';
    final sanitizedToc = sanitizeProseSpacing(tocFused);
    expect(sanitizedToc, 'CONTENTS Cover Title Page Chapter 1 Chapter 2');

    const quoteFused = 'He said"Focus"and walked;then paused.';
    final sanitizedQuote = sanitizeProseSpacing(quoteFused);
    expect(sanitizedQuote, 'He said "Focus" and walked; then paused.');

    const deadPoetsSample = 'Thefourboyswhocarriedbannersmarchedsolemnlytothedais, '
        'followedslowlybytheelderlymen, thelastofwhomproudlycarriedthelightedcandle. '
        'Headmaster Gale Nolan, '
        'ahuskymaninhisearlysixties, stoodatthepodiumwatchingexpectantlyastheprocessionconcluded. '
        '“Ladiesandgentlemen...boys...” '
        'hesaiddramatically, pointingtowardthemanwiththecandle. '
        '“Thelightofknowledge.” Theaudienceapplaudedpolitelyastheoldergentlemansteppedslowlyforwardwiththecandle.';
    final sanitizedProse = sanitizeProseSpacing(deadPoetsSample);
    expect(sanitizedProse, contains('The four boys who carried banners marched solemnly to the dais'));
    expect(sanitizedProse, contains('followed slowly by the elderly men'));
    expect(sanitizedProse, contains('the last of whom proudly carried the lighted candle'));
    expect(sanitizedProse, contains('Headmaster Gale Nolan'));
    expect(sanitizedProse, contains('a husky man in his early sixties'));
    expect(sanitizedProse, contains('stood at the podium watching expectantly as the procession concluded'));
    expect(sanitizedProse, contains('Ladies and gentlemen'));
    expect(sanitizedProse, contains('he said dramatically'));
    expect(sanitizedProse, contains('pointing toward the man with the candle'));
    expect(sanitizedProse, contains('The light of knowledge'));
    expect(sanitizedProse, contains('The audience applauded politely as the older gentleman stepped slowly forward with the candle'));
  });

  test('sanitizeProseSpacing preserves technical compounds', () {
    expect(sanitizeProseSpacing('neuroplasticity'), 'neuroplasticity');
    expect(sanitizeProseSpacing('electromagnetism'), 'electromagnetism');
    expect(sanitizeProseSpacing('thermodynamics'), 'thermodynamics');
    expect(sanitizeProseSpacing('photosynthesis'), 'photosynthesis');
    expect(sanitizeProseSpacing('crystallography'), 'crystallography');
    expect(sanitizeProseSpacing('biotechnology'), 'biotechnology');
    expect(sanitizeProseSpacing('paleontology'), 'paleontology');
    expect(sanitizeProseSpacing('socioeconomic'), 'socioeconomic');
    expect(sanitizeProseSpacing('cardiovascular'), 'cardiovascular');
    expect(sanitizeProseSpacing('counterintuitive'), 'counterintuitive');
  });

  test('10,000-char continuous text satisfies hard 450-char ceiling while preserving 100% fidelity', () {
    final sentences = List.generate(
      150,
      (i) => 'In observation study #${i + 1}, researcher Dr. Smith noted significant cognitive fidelity variations across participants. ',
    );
    final longSource = sentences.join();
    expect(longSource.length, greaterThan(10000));

    final spans = [
      {
        'start': 0,
        'end': longSource.length,
        'page_start': 1,
        'page_end': 25,
        'type': 'paragraph',
      },
    ];

    final chunks = LosslessChunker().build(
      documentId: 'large-corpus-doc',
      canonicalText: longSource,
      spans: spans,
    );

    expect(chunks, isNotEmpty);
    // 100% byte-exact reconstruction
    expect(chunks.map((c) => c['raw_text']).join(), longSource);

    // Hard 450-character ceiling per chunk for single-screen mobile reading
    for (final c in chunks) {
      final raw = c['raw_text'] as String;
      expect(raw.length, lessThanOrEqualTo(450),
          reason: 'Chunk ${c['sequence']} exceeds 450 characters: ${raw.length} chars');
    }

    // Sequence integrity
    expect(chunks.first['sequence'], 1);
    expect(chunks.last['sequence'], chunks.length);
  });
}
