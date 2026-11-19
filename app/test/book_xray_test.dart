// License: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../tool/book_xray.dart' as xray;

void main() {
  test('Run BookXRay on all 7 adversarial books', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final books = [
      '../backend/data/adversarial/book_1a_messy_ocr_seminar.pdf',
      '../backend/data/adversarial/book_1b_trade_nonfiction.pdf',
      '../backend/data/adversarial/book_1c_trade_epub.epub',
      '../backend/data/adversarial/book_2a_skewed_academic.pdf',
      '../backend/data/adversarial/book_2b_classic_novel.pdf',
      '../backend/data/adversarial/book_2c_multilingual.pdf',
      '../backend/data/adversarial/book_3a_stress_unseen.pdf',
    ];
    for (final b in books) {
      await xray.main([b]);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
