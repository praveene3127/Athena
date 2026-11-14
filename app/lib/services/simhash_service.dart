import 'package:flutter/foundation.dart';
import 'package:athena/services/rust_engine_bridge.dart';

/// Portable SimHash implementation using two unsigned 32-bit halves.
/// Dart Web and native runtimes therefore use identical arithmetic.
class SimHashFingerprint {
  final int high32;
  final int low32;
  const SimHashFingerprint(this.high32, this.low32);
}

class SimHashService {
  static const int _mask32 = 0xFFFFFFFF;
  static final RegExp _nonAlnum = RegExp(r'[^a-z0-9]');

  static SimHashFingerprint computeSimHash64(String text) {
    if (text.trim().isEmpty) return const SimHashFingerprint(0, 0);

    try {
      final rustHash = RustEngineBridge.instance.computeSimhash64(text);
      if (rustHash != null && rustHash != 0) {
        final high = (rustHash >> 32) & _mask32;
        final low = rustHash & _mask32;
        return SimHashFingerprint(high, low);
      }
    } catch (e) {
      debugPrint('[Athena SimHashService] native bridge notice: $e');
    }

    final votes = List<int>.filled(64, 0);
    for (final raw in text.toLowerCase().split(RegExp(r'\s+'))) {
      final clean = raw.replaceAll(_nonAlnum, '');
      if (clean.length < 3) continue;
      var hash = 0x811C9DC5;
      var high = 0x9E3779B9;
      for (final unit in clean.codeUnits) {
        hash = ((hash ^ unit) * 0x01000193) & _mask32;
        high = ((high ^ unit) * 0x5BD1E995) & _mask32;
      }
      high = (high ^ (high >> 13)) & _mask32;
      for (var bit = 0; bit < 32; bit++) {
        votes[bit] += ((hash >> bit) & 1) == 1 ? 1 : -1;
        votes[bit + 32] += ((high >> bit) & 1) == 1 ? 1 : -1;
      }
    }
    var low = 0;
    var high = 0;
    for (var bit = 0; bit < 32; bit++) {
      if (votes[bit] > 0) low = (low | (1 << bit)) & _mask32;
      if (votes[bit + 32] > 0) high = (high | (1 << bit)) & _mask32;
    }
    return SimHashFingerprint(high, low);
  }

  static int popcnt32(int value) {
    var x = value & _mask32;
    x = (x - ((x >> 1) & 0x55555555)) & _mask32;
    x = ((x & 0x33333333) + ((x >> 2) & 0x33333333)) & _mask32;
    x = ((x + (x >> 4)) & 0x0F0F0F0F) & _mask32;
    return ((x * 0x01010101) & _mask32) >> 24;
  }

  static int hammingDistance(SimHashFingerprint a, SimHashFingerprint b) =>
      popcnt32(a.high32 ^ b.high32) + popcnt32(a.low32 ^ b.low32);

  static double similarity(SimHashFingerprint a, SimHashFingerprint b) =>
      1.0 - hammingDistance(a, b) / 64.0;

  static List<Map<String, dynamic>> findRelatedChunks({
    required SimHashFingerprint targetHash,
    required List<Map<String, dynamic>> candidates,
    String? currentChunkId,
    int topK = 3,
    double minSimilarity = 0.65,
  }) {
    if (candidates.isEmpty || (targetHash.high32 == 0 && targetHash.low32 == 0)) {
      return [];
    }
    final scored = <Map<String, dynamic>>[];
    for (final chunk in candidates) {
      final id = chunk['id']?.toString() ?? chunk['chunk_id']?.toString() ?? '';
      if (currentChunkId != null && id == currentChunkId) continue;
      final storedHigh = (chunk['simhash_hi'] as num?)?.toInt();
      final storedLow = (chunk['simhash_lo'] as num?)?.toInt();
      final providedHash = chunk['simhash'];
      final text = chunk['raw_text']?.toString() ?? '';
      if (text.isEmpty &&
          (storedHigh == null || storedLow == null) &&
          providedHash is! SimHashFingerprint) {
        continue;
      }
      final candidateHash = storedHigh != null && storedLow != null
          ? SimHashFingerprint(storedHigh & _mask32, storedLow & _mask32)
          : providedHash is SimHashFingerprint
              ? providedHash
              : computeSimHash64(text);
      final distance = hammingDistance(targetHash, candidateHash);
      final score = 1.0 - distance / 64.0;
      if (score >= minSimilarity) {
        scored.add({
          ...chunk,
          'simhash_distance': distance,
          'similarity_score': score
        });
      }
    }
    scored.sort((a, b) =>
        (b['similarity_score'] as num).compareTo(a['similarity_score'] as num));
    return scored.length > topK ? scored.sublist(0, topK) : scored;
  }
}
