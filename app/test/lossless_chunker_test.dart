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
}
