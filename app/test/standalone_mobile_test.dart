import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:athena/core/config/config.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/models/document.dart';
import 'package:athena/features/reader/controllers/reader_feed_builder.dart';
import 'package:athena/core/api/api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Standalone Mobile Mode & Speed Parity Tests', () {
    test('AppConfig resolves standalone mobile mode without loopback trap', () {
      final url = AppConfig.resolveBaseUrl(
        isWeb: false,
        host: '',
        origin: '',
        isMobile: true,
      );
      expect(url, equals(''));
      expect(url, isNot(contains('127.0.0.1')));
    });

    test('LosslessChunker produces Python-matching -c0001 chunk IDs and <= 65 words', () {
      const docId = 'test_book_123';
      final text = List.generate(
        150,
        (i) => 'Word$i in chapter one of the authentic literary book.',
      ).join(' ');

      final sanitized = sanitizeProseSpacing(text);
      expect(sanitized, isNotEmpty);
      expect(sanitized, isNot(contains('Word0in')));

      final chunks = LosslessChunker().build(
        documentId: docId,
        canonicalText: sanitized,
        spans: [
          {
            'start': 0,
            'end': sanitized.length,
            'page_start': 1,
            'page_end': 1,
            'type': 'paragraph',
          }
        ],
      );

      expect(chunks, isNotEmpty);
      // Assert chunk ID format matches Python: ${docId}-c0001
      expect(chunks[0]['id'], equals('$docId-c0001'));
      expect(chunks[0]['id'], matches(RegExp(r'-c\d{4}$')));

      // Assert each chunk is <= 65 words
      for (final chunk in chunks) {
        final raw = chunk['raw_text'] as String;
        final wordCount = raw.trim().split(RegExp(r'\s+')).length;
        expect(wordCount, lessThanOrEqualTo(65));
        expect(raw.length, lessThanOrEqualTo(380));
      }
    });

    test('Context Cards are interleaved deterministically matching chunk IDs', () {
      const docId = 'test_book_456';
      final chunks = <ReaderItem>[
        const ReaderItem(
          id: '$docId-c0001',
          type: 'reading_chunk',
          sequence: 1,
          text: 'First chapter of the story.',
        ),
        const ReaderItem(
          id: '$docId-c0002',
          type: 'reading_chunk',
          sequence: 2,
          text: 'Second chapter of the story.',
        ),
        const ReaderItem(
          id: '$docId-c0003',
          type: 'reading_chunk',
          sequence: 3,
          text: 'Third chapter with historical analysis.',
        ),
      ];

      const card = ReaderItem(
        id: 'card_empirical_1',
        type: 'context_card',
        insertAfter: '$docId-c0003',
        sequence: 3,
        title: 'EMPIRICAL STUDY: Cognitive Impact',
        body: 'Research indicates substantial reading gains. ||REVEAL|| Controlled trial of 200 participants.',
        exactQuote: 'historical analysis',
      );

      final feed = buildInterleavedFeed(
        rawItems: chunks,
        dynamicCardsBySeq: {3: card},
        dismissedCardIds: {},
        showContextCards: true,
      );

      expect(feed.length, equals(4));
      expect(feed.any((it) => it.isContextCard && it.id == 'card_empirical_1'), isTrue);
    });

    test('directTestProvider fails cleanly on empty API key without calling 127.0.0.1:8000', () async {
      final res = await ApiClient.directTestProvider(
        provider: 'gemini',
        apiKey: '',
      );
      expect(res['ok'], isFalse);
      expect(res['message'], contains('API key is required'));
    });

    test('uploadDocument drains Stream<List<int>> and runs isolate parser without unsendable object error', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final sampleText = utf8.encode('Sample book text containing authentic literature with complete sentences.');
      final stream = Stream<List<int>>.fromIterable([sampleText]);
      final client = ApiClient();
      final docId = await client.uploadDocument(
        stream,
        sampleText.length,
        'test.pdf',
      );
      expect(docId, isNotEmpty);
      expect(docId, startsWith('doc_'));
    });
  });
}
