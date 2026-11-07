import 'dart:convert';
import 'dart:typed_data';
import 'package:athena/services/simhash_service.dart';

/// Flat Contiguous Binary Tape (`.athena.bin`) for zero-JSON, zero-GC instant book opening.
///
/// Binary Layout:
/// - Header (16 bytes):
///   * 0..4: Magic bytes 'ATHN' (0x4154484E)
///   * 4..8: Format version (uint32 = 1)
///   * 8..12: Total chunk count N (uint32)
///   * 12..16: Total UTF-8 string pool byte length (uint32)
/// - Index Table (N * 16 bytes):
///   * 0..4: utf8_start_offset (uint32)
///   * 4..8: utf8_byte_length (uint32)
///   * 8..12: page_number (uint32)
///   * 12..16: simhash_low32 (uint32)
/// - Contiguous UTF-8 Payload Blob:
///   * Back-to-back UTF-8 bytes for all chunk texts.
class BinaryBookTape {
  static const int magic = 0x4154484E; // 'ATHN'
  static const int currentVersion = 1;
  static const int headerSize = 16;
  static const int indexRecordSize = 16;

  final int chunkCount;
  final int utf8ByteLength;
  final ByteData _indexData;
  final Uint8List _payloadBlob;
  final Uint8List rawBytes;

  BinaryBookTape._({
    required this.chunkCount,
    required this.utf8ByteLength,
    required ByteData indexData,
    required Uint8List payloadBlob,
    required this.rawBytes,
  })  : _indexData = indexData,
        _payloadBlob = payloadBlob;

  /// Serializes a list of chunk maps into a contiguous flat binary buffer.
  static Uint8List encode({required List<Map<String, dynamic>> chunks}) {
    final count = chunks.length;
    final textBytesList = <Uint8List>[];
    int totalUtf8Bytes = 0;

    for (final c in chunks) {
      final text = c['raw_text']?.toString() ?? c['text']?.toString() ?? '';
      final encoded = utf8.encode(text);
      textBytesList.add(encoded);
      totalUtf8Bytes += encoded.length;
    }

    final totalSize = headerSize + (count * indexRecordSize) + totalUtf8Bytes;
    final buffer = Uint8List(totalSize);
    final byteData = ByteData.sublistView(buffer);

    // Write Header
    byteData.setUint32(0, magic, Endian.big);
    byteData.setUint32(4, currentVersion, Endian.big);
    byteData.setUint32(8, count, Endian.big);
    byteData.setUint32(12, totalUtf8Bytes, Endian.big);

    // Write Index Table & Pack String Payload
    int currentPayloadOffset = 0;
    int indexCursor = headerSize;
    final payloadStart = headerSize + (count * indexRecordSize);

    for (int i = 0; i < count; i++) {
      final chunk = chunks[i];
      final textBytes = textBytesList[i];
      final textLen = textBytes.length;
      final page = (chunk['page_number'] as num?)?.toInt() ??
          (chunk['page'] as num?)?.toInt() ??
          1;
      final suppliedHash = chunk['simhash'];
      final simhash = suppliedHash is SimHashFingerprint
          ? suppliedHash.low32
          : (suppliedHash as num?)?.toInt() ?? 0;
      final simhashLow = simhash & 0xFFFFFFFF;

      // Index Entry (16 bytes)
      byteData.setUint32(indexCursor + 0, currentPayloadOffset, Endian.big);
      byteData.setUint32(indexCursor + 4, textLen, Endian.big);
      byteData.setUint32(indexCursor + 8, page, Endian.big);
      byteData.setUint32(indexCursor + 12, simhashLow, Endian.big);

      // Copy UTF-8 bytes to payload blob
      buffer.setRange(
        payloadStart + currentPayloadOffset,
        payloadStart + currentPayloadOffset + textLen,
        textBytes,
      );

      currentPayloadOffset += textLen;
      indexCursor += indexRecordSize;
    }

    return buffer;
  }

  /// Deserializes a binary book tape in O(1) time without decoding string blobs upfront.
  static BinaryBookTape fromBytes(Uint8List bytes) {
    if (bytes.length < headerSize) {
      throw FormatException(
          'BinaryBookTape payload too small: ${bytes.length} bytes');
    }

    final byteData = ByteData.sublistView(bytes);
    final m = byteData.getUint32(0, Endian.big);
    if (m != magic) {
      throw FormatException(
          'Invalid BinaryBookTape magic: 0x${m.toRadixString(16)}');
    }

    final version = byteData.getUint32(4, Endian.big);
    if (version != currentVersion) {
      throw FormatException('Unsupported BinaryBookTape version: $version');
    }

    final count = byteData.getUint32(8, Endian.big);
    final utf8Length = byteData.getUint32(12, Endian.big);
    final expectedIndexBytes = count * indexRecordSize;
    final payloadStart = headerSize + expectedIndexBytes;

    if (bytes.length < payloadStart + utf8Length) {
      throw FormatException('Truncated BinaryBookTape buffer');
    }

    final indexData = ByteData.sublistView(bytes, headerSize, payloadStart);
    final payloadBlob =
        Uint8List.sublistView(bytes, payloadStart, payloadStart + utf8Length);

    return BinaryBookTape._(
      chunkCount: count,
      utf8ByteLength: utf8Length,
      indexData: indexData,
      payloadBlob: payloadBlob,
      rawBytes: bytes,
    );
  }

  /// O(1) random-access slice read of a chunk's raw UTF-8 text.
  String getChunkText(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, this, 'chunkCount');
    }
    final offset = index * indexRecordSize;
    final start = _indexData.getUint32(offset + 0, Endian.big);
    final len = _indexData.getUint32(offset + 4, Endian.big);

    return utf8.decode(Uint8List.sublistView(_payloadBlob, start, start + len));
  }

  /// O(1) lookup of a chunk's source page number.
  int getChunkPage(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, this, 'chunkCount');
    }
    return _indexData.getUint32((index * indexRecordSize) + 8, Endian.big);
  }

  /// O(1) lookup of a chunk's 32-bit SimHash signature.
  int getChunkSimHashLow(int index) {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.index(index, this, 'chunkCount');
    }
    return _indexData.getUint32((index * indexRecordSize) + 12, Endian.big);
  }

  /// Pre-computes deterministic text geometry metrics for zero-jank optical layout.
  static Map<String, dynamic> computeGeometryMetrics(String text) {
    final charCount = text.length;
    final lineBreaks = '\n'.allMatches(text).length;
    final hasCodeBlock = text.contains('```') || text.contains('    ');

    // Estimated lines at standard 390px viewport width (~40-44 characters per line in 17.5px font)
    final estimatedLines = (charCount / 42.0).ceil() + lineBreaks;

    // Deterministic font scale recommendation
    final double idealFontSize;
    if (charCount < 220) {
      idealFontSize = 19.0; // Short chunk -> generous optical size
    } else if (charCount <= 320) {
      idealFontSize = 17.5; // Medium chunk -> standard optical size
    } else {
      idealFontSize = 16.0; // Dense chunk -> compact optical size
    }

    return {
      'char_count': charCount,
      'line_break_count': lineBreaks,
      'has_code_block': hasCodeBlock,
      'estimated_lines': estimatedLines,
      'ideal_font_size': idealFontSize,
    };
  }
}
