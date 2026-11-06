import '../app/lib/services/lossless_chunker.dart';

void main() {
  const input = 'Thefourboyswhocarriedbanners candle.HeadmasterGaleNolan TitlePage\nChapter1';
  final output = sanitizeProseSpacing(input);
  print('INPUT: $input');
  print('OUTPUT:\n$output');
}
