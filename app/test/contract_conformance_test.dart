import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/services/segmentation_policy.dart';
import 'package:athena/services/lossless_chunker.dart';

void main() {
  late Map<String, dynamic> contract;

  setUpAll(() {
    // Try multiple relative paths to find contracts/athena-contract.json
    final candidates = [
      '../contracts/athena-contract.json',
      'contracts/athena-contract.json',
      '../../contracts/athena-contract.json',
    ];
    File? foundFile;
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) {
        foundFile = f;
        break;
      }
    }
    expect(foundFile, isNotNull, reason: 'contracts/athena-contract.json must exist');
    contract = jsonDecode(foundFile!.readAsStringSync()) as Map<String, dynamic>;
  });

  group('Cross-Language Contract Conformance', () {
    test('AppConfig limits and version match canonical contract', () {
      final limits = contract['limits'] as Map<String, dynamic>;
      expect(AppConfig.statusPollMs, limits['status_poll_ms']);
      expect(AppConfig.cardMaxWords, limits['card_max_words']);
      expect(AppConfig.askMaxQuestionChars, limits['ask_max_question_chars']);
      expect(AppConfig.appVersion, contract['version']);
    });

    test('SegmentationPolicy constants match canonical contract', () {
      final sp = contract['segmentation_policy'] as Map<String, dynamic>;
      expect(SegmentationPolicy.minWords, sp['min_words']);
      expect(SegmentationPolicy.maxWords, sp['max_words']);
      expect(SegmentationPolicy.preferredMaxChars, sp['soft_max_chars']);
      expect(SegmentationPolicy.defaultTargetWords, sp['target_words']);
      expect(SegmentationPolicy.chunkIdPadWidth, sp['chunk_id_pad_width']);
      expect(SegmentationPolicy.version, sp['version']);
      expect(SegmentationPolicy.offsetProtocol, sp['offset_protocol']);
    });

    test('Document states match canonical contract', () {
      final states = (contract['document_states'] as List).cast<String>();
      expect(SegmentationPolicy.documentStates, states);
    });

    test('MethodChannel configuration matches canonical contract', () {
      final mc = contract['method_channel'] as Map<String, dynamic>;
      expect(SegmentationPolicy.methodChannel, mc['channel']);
      final methods = (mc['methods'] as List).cast<String>();
      expect(SegmentationPolicy.methodChannelMethods, methods);
    });

    test('Golden chunking fixture matches byte-exactness and word count', () {
      final fixture = contract['golden_fixture'] as Map<String, dynamic>;
      final sampleText = fixture['sample_text'] as String;
      final expectedWords = fixture['expected_word_count'] as int;

      final spans = [
        {
          'start': 0,
          'end': sampleText.length,
          'page_number': 1,
          'type': 'paragraph',
        }
      ];

      final chunks = LosslessChunker().build(
        documentId: 'contract_test_doc',
        canonicalText: sampleText,
        spans: spans,
      );

      expect(chunks.isNotEmpty, isTrue);

      // Lossless invariant: "".join(chunk['raw_text']) == originalText
      final reconstructed = chunks.map((c) => c['raw_text']).join('');
      expect(reconstructed, sampleText);

      // Word count invariant
      final totalWords = chunks.fold<int>(0, (sum, c) {
        final text = (c['raw_text'] ?? '').toString().trim();
        final count = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
        return sum + count;
      });
      expect(totalWords, expectedWords);
    });
  });
}
