import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:athena/core/theme/theme.dart';
import 'package:athena/services/ingestion_pipeline.dart';
import 'package:athena/services/lossless_chunker.dart';
import 'package:athena/services/segmentation_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const englishProse =
      'The scientific revolution inaugurated an era of unprecedented empirical discovery. '
      'Natural philosophers recognized that mathematical modeling and controlled experimentation '
      'could unveil universal principles of physical reality. Through careful observation, humanity '
      'began to comprehend the intricate mechanics governing celestial motion and earthly dynamics. '
      'Every newly discovered principle laid the foundation for transformative technological advancements.';

  const frenchGermanProse =
      "L'intelligence artificielle et l'apprentissage automatique transforment la société moderne. "
      "Les chercheurs développent des algorithmes capables d'analyser des ensembles de données complexes. "
      'Die präzise mathematische Modellierung vernetzter Systeme erfordert tiefes theoretisches Verständnis. '
      'Überraschende wissenschaftliche Erkenntnisse fördern den nachhaltigen industriellen Fortschritt. '
      'Dieser interdisziplinäre Dialog bereichert die globale Forschungsgemeinschaft ungemein.';

  const russianProse =
      'Классическая литература раскрывает глубокие философские вопросы человеческого бытия и сознания. '
      'Исследование культурного наследия обогащает внутренний мир читателя и открывает новые горизонты. '
      'Гармония глубокой мысли и выразительного слова формирует подлинную мудрость поколений. '
      'Научные труды великих мыслителей продолжают вдохновлять исследователей во всем мире. '
      'Преемственность знаний служит прочным фундаментом духовного развития общества.';

  const hindiProse =
      'साहित्य समाज का दर्पण होता है और मानवीय संवेदनाओं को गहराई से उजागर करता है। '
      'ज्ञान और तर्कसंगत विचार का संगम प्रत्येक व्यक्ति को विवेकशील और संवेदनशील बनाता है। '
      'प्राचीन ग्रंथों में निहित दार्शनिक चिंतन आज के युग में भी अत्यंत प्रासंगिक और प्रेरणादायक है। '
      'शिक्षा और संस्कृति का समन्वय समाज को प्रगति और सौहार्द के मार्ग पर अग्रसर करता है। '
      'सत्य और अहिंसा के शाश्वत मूल्य मानवता के कल्याण का मार्ग प्रशस्त करते हैं।';

  const tamilProse =
      'கல்வி என்பது மனிதனின் அறியாமையை போக்கி நல்வழிப்படுத்தும் ஒரு சக்திவாய்ந்த கருவியாகும். '
      'நல்ல நூல்களை வாசிப்பது மனித மனதிற்கு அமைதியையும் ஆழமான சிந்தனையையும் தருகிறது. '
      'சமுதாய முன்னேற்றத்திற்கு அறிவு வளர்ச்சி இன்றியமையாதது என்பதை வரலாறு நமக்கு உணர்த்துகிறது. '
      'அறிவியலும் தத்துவமும் இணைந்து மனித குலத்தின் வாழ்க்கைத் தரத்தை உயர்த்துகின்றன. '
      'பண்டைய தமிழ் இலக்கியங்கள் அறநெறிகளையும் சமூக நல்லிணக்கத்தையும் வலியுறுத்துகின்றன.';

  const arabicProse =
      'إن القراءة غذاء العقل ونافذة يطل منها الإنسان على عوالم جديدة وتجارب ملهمة ومفيدة. '
      'المعرفة تبني الحضارات وترتقي بالأمم نحو مستقبل أكثر إشراقاً وتطوراً وازدهاراً دائماً. '
      'التفكر والتدبر في العلوم والآداب يمنح الروح عمقاً وبصيرة نافذة لفهم الكون والمجتمع. '
      'العلم والبحث المستمر هما الأساس المتين لكل نهضة إنسانية مستدامة عبر التاريخ البشري. '
      'الحوار بين الثقافات يثري الفكر الإنساني ويعزز قيم التسامح والتعايش السلمي بين الشعوب.';

  const chineseProse =
      '读书是一场穿越时空的心灵对话。在静谧的书页之间，历史的智慧与当下的思考悄然交汇。'
      '探索未知的旅程不仅拓宽了视野，更赋予生命以深刻的意义与宁静的力量。'
      '科学与人文的融合推动着人类社会的持续进步与繁荣。每一项重大发现都凝聚着前人无数的心血。'
      '面对广袤的宇宙与复杂的世界，保持谦逊与好奇心是求知探索最重要的品质。';

  const japaneseProse =
      '読書は知識を深め、心を豊かにするための素晴らしい習慣です。'
      '静かな時間の中で言葉と対話することは、新たな視点と深い洞察をもたらします。'
      '先人たちが築き上げた知識の集積は、未来を切り開くための確固たる道標となります。'
      '科学技術の発展と豊かな人間性の調和こそが、持続可能な社会の基盤となるでしょう。'
      '好奇心を持ち続けて学びを深めることが、人生を豊かに彩る鍵となります。';

  group('Pass 3: Unicode Page Quality Invariant (LNG-01)', () {
    test('Valid prose across 8 global scripts isAcceptable == true', () {
      final samples = <String, String>{
        'English': englishProse,
        'French/German': frenchGermanProse,
        'Russian': russianProse,
        'Hindi': hindiProse,
        'Tamil': tamilProse,
        'Arabic': arabicProse,
        'Chinese': chineseProse,
        'Japanese': japaneseProse,
      };

      for (final entry in samples.entries) {
        final score = DocumentIngestionPipeline.computePageQuality(entry.value);
        expect(score.isAcceptable, isTrue,
            reason: '${entry.key} prose should be accepted by computePageQuality '
                '(alphaRatio: ${score.alphaRatio}, validWordRatio: ${score.validWordRatio}, '
                'symbolNoiseRatio: ${score.symbolNoiseRatio})');
        expect(score.symbolNoiseRatio, lessThanOrEqualTo(0.15));
        expect(score.alphaRatio, greaterThanOrEqualTo(0.60));
      }
    });

    test('Corrupted OCR symbol noise is rejected', () {
      const corruptedOcr =
          r'\ | ~ ^ { } :- -- ll) 1\ () \\|||| //\\ \1\0\0 :- :- '
          r'Corrupt3d \||| text %%% $$$ &&& +++ === ~~~ ^^^';
      final score = DocumentIngestionPipeline.computePageQuality(corruptedOcr);
      expect(score.isAcceptable, isFalse,
          reason: 'Severe OCR corruption must be rejected');
    });
  });

  group('Pass 3: Lossless UTF-8 Chunking & 6-Digit IDs (LNG-02, XLG-01)', () {
    final corpora = <String, String>{
      'English': englishProse,
      'French/German': frenchGermanProse,
      'Russian': russianProse,
      'Hindi': hindiProse,
      'Tamil': tamilProse,
      'Arabic': arabicProse,
      'Chinese': chineseProse,
      'Japanese': japaneseProse,
    };

    for (final entry in corpora.entries) {
      test('Lossless reconstruction and UTF-8 offsets for ${entry.key}', () {
        final text = entry.value;
        final docId = 'doc_${entry.key.toLowerCase().replaceAll('/', '_')}';
        final spans = [
          {
            'start': 0,
            'end': text.length,
            'page_start': 1,
            'page_end': 1,
            'role': 'chapter',
          }
        ];

        final chunks = LosslessChunker().build(
          documentId: docId,
          canonicalText: text,
          spans: spans,
          initialSequence: 1,
          offsetDelta: 0,
        );

        expect(chunks.isNotEmpty, isTrue);

        // 1. Lossless string reconstruction
        final reconstructed =
            chunks.map((c) => c['raw_text'] as String).join('');
        expect(reconstructed, equals(text),
            reason: '${entry.key} reconstructed text must equal canonical text exactly');

        // 2. Lossless SHA-256 match
        final expectedSha = sha256.convert(utf8.encode(text)).toString();
        final actualSha = sha256.convert(utf8.encode(reconstructed)).toString();
        expect(actualSha, equals(expectedSha));

        // 3. Exact UTF-8 byte offsets (LNG-02)
        int expectedStartByte = 0;
        for (var i = 0; i < chunks.length; i++) {
          final c = chunks[i];
          final raw = c['raw_text'] as String;
          final startByte = c['start_offset'] as int;
          final endByte = c['end_offset'] as int;
          final utf8ByteLen = utf8.encode(raw).length;

          expect(startByte, equals(expectedStartByte),
              reason: 'Chunk $i start_offset must equal previous chunk end_offset');
          expect(endByte, equals(startByte + utf8ByteLen),
              reason: 'Chunk $i end_offset must match start + exact UTF-8 byte length');

          // Verify chunk ID format (e.g. doc-c0001 or doc-c000001)
          final chunkId = c['id'] as String;
          expect(chunkId, matches(RegExp(r'-c\d{4,6}$')),
              reason: 'Chunk ID must have valid padded digits: $chunkId');

          expectedStartByte = endByte;
        }

        expect(expectedStartByte, equals(utf8.encode(text).length),
            reason: 'Final chunk end_offset must equal total UTF-8 byte length');
      });
    }
  });

  group('Pass 3: Multilingual Sentence Boundaries & Word Counts (LNG-03)', () {
    test('CJK character counting scales ~2.5 chars per word unit', () {
      const cjkSample = '读书是一场穿越时空的心灵对话。在静谧的书页之间，历史的智慧与当下的思考悄然交汇。';
      final wordCount = SegmentationPolicy.countWords(cjkSample);
      // cjkSample has 36 CJK chars + 2 full-stops = 38 non-ws chars. ~36 / 2.5 ~= 15 words.
      expect(wordCount, greaterThanOrEqualTo(10));
      expect(wordCount, lessThanOrEqualTo(20));
    });

    test('findSentenceBoundaries splits CJK text at full-stops (。)', () {
      const cjkSentences = '第一句话是关于科学的。第二句话是关于文学的。第三句话是关于艺术的。';
      final boundaries = SegmentationPolicy.findSentenceBoundaries(cjkSentences);
      expect(boundaries.length, greaterThanOrEqualTo(2));
    });

    test('findSentenceBoundaries splits Indic text at danda (।)', () {
      const hindiSentences =
          'साहित्य समाज का दर्पण होता है। ज्ञान और विचार का संगम व्यक्ति को विवेकशील बनाता है।';
      final boundaries = SegmentationPolicy.findSentenceBoundaries(hindiSentences);
      expect(boundaries.length, greaterThanOrEqualTo(1));
    });

    test('findSentenceBoundaries splits Arabic text at question mark (؟)', () {
      const arabicSentences = 'هل القراءة غذاء العقل؟ المعرفة تبني الحضارات وترتقي بالأمم.';
      final boundaries = SegmentationPolicy.findSentenceBoundaries(arabicSentences);
      expect(boundaries.length, greaterThanOrEqualTo(1));
    });
  });

  group('Pass 3: RTL Directionality Detection (LNG-04)', () {
    test('Detects Arabic and Hebrew as RTL', () {
      expect(AppTheme.isRtlText(arabicProse), isTrue);
      const hebrewProse = 'שלום עליכם, ספרות יפה מעשירה את רוח האדם ומפתחת את המחשבה.';
      expect(AppTheme.isRtlText(hebrewProse), isTrue);
    });

    test('Detects Latin, Cyrillic, Indic, and CJK as LTR', () {
      expect(AppTheme.isRtlText(englishProse), isFalse);
      expect(AppTheme.isRtlText(frenchGermanProse), isFalse);
      expect(AppTheme.isRtlText(russianProse), isFalse);
      expect(AppTheme.isRtlText(hindiProse), isFalse);
      expect(AppTheme.isRtlText(tamilProse), isFalse);
      expect(AppTheme.isRtlText(chineseProse), isFalse);
      expect(AppTheme.isRtlText(japaneseProse), isFalse);
    });
  });
}
