import 'dart:collection';
import 'package:sqflite/sqflite.dart';
import 'package:athena/services/local_database.dart';

/// Keyset windowed repository for reader chunk and card access.
///
/// Features:
/// 1. Fast keyset pagination:
///    `WHERE document_id = ? AND sequence >= ? ORDER BY sequence ASC LIMIT ?`
/// 2. Memory-bounded LRU cache of ±200 chunks around active sequence
///    to open even a 100,000-chunk book in < 50ms with constant RAM.
/// 3. Direct integer `page_start` column retrieval (no jsonDecode in loops).
/// 4. Canonical reading position persistence:
///    `(document_id, chunk_seq, intra_byte, updated_at)`
class BookRepository {
  final LocalDatabase _db;
  final int cacheCapacity;

  BookRepository({
    LocalDatabase? db,
    this.cacheCapacity = 400,
  }) : _db = db ?? LocalDatabase.instance;

  // DocumentId -> (Sequence -> Chunk) LRU cache
  final Map<String, _LruChunkCache> _documentCaches = {};

  _LruChunkCache _getCache(String documentId) {
    return _documentCaches.putIfAbsent(
      documentId,
      () => _LruChunkCache(cacheCapacity),
    );
  }

  /// Clears cache for a given document or all documents
  void invalidate([String? documentId]) {
    if (documentId != null) {
      _documentCaches.remove(documentId);
    } else {
      _documentCaches.clear();
    }
  }

  /// Fast keyset window query for chunks around [startSequence].
  ///
  /// Uses indexed keyset filtering:
  /// `WHERE document_id = ? AND sequence >= ? ORDER BY sequence ASC LIMIT ?`
  Future<List<Map<String, dynamic>>> getChunkWindow(
    String documentId, {
    int startSequence = 0,
    int limit = 50,
  }) async {
    final cache = _getCache(documentId);

    // Check if we can satisfy from cache completely
    final cached = <Map<String, dynamic>>[];
    bool allCached = true;
    for (int seq = startSequence; seq < startSequence + limit; seq++) {
      final item = cache.get(seq);
      if (item != null) {
        cached.add(item);
      } else {
        allCached = false;
        break;
      }
    }
    if (allCached && cached.length == limit) {
      return cached;
    }

    final db = await _db.database;
    final rows = await db.rawQuery(
      '''
      SELECT id, document_id, sequence, section_title, section_role,
             raw_text, page_start, page_number, source_pages_json,
             start_offset, end_offset, checksum, boundary_method, canonical_sha256
      FROM reading_chunks
      WHERE document_id = ? AND sequence >= ?
      ORDER BY sequence ASC
      LIMIT ?
      ''',
      [documentId, startSequence, limit],
    );

    final result = <Map<String, dynamic>>[];
    for (final r in rows) {
      final map = Map<String, dynamic>.from(r);
      // Ensure integer page_start is populated without jsonDecode overhead
      final pStart = (map['page_start'] as num?)?.toInt() ??
          (map['page_number'] as num?)?.toInt() ?? 1;
      map['page_start'] = pStart;
      map['page_number'] = pStart;

      final seq = (map['sequence'] as num).toInt();
      cache.put(seq, map);
      result.add(map);
    }

    return result;
  }

  /// Loads an active LRU window of ±[radius] chunks (default ±200) around [centerSequence].
  Future<List<Map<String, dynamic>>> loadWindowAround(
    String documentId, {
    required int centerSequence,
    int radius = 200,
  }) async {
    final start = (centerSequence - radius).clamp(0, 10000000);
    final count = radius * 2 + 1;
    return getChunkWindow(
      documentId,
      startSequence: start,
      limit: count,
    );
  }

  /// Reads a single chunk by sequence, querying cache first then DB.
  Future<Map<String, dynamic>?> getChunkBySequence(
    String documentId,
    int sequence,
  ) async {
    final cache = _getCache(documentId);
    final cached = cache.get(sequence);
    if (cached != null) return cached;

    final window = await getChunkWindow(
      documentId,
      startSequence: sequence,
      limit: 1,
    );
    return window.isNotEmpty ? window.first : null;
  }

  /// Gets total chunk count for a document.
  Future<int> getChunkCount(String documentId) async {
    final db = await _db.database;
    final count = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM reading_chunks WHERE document_id = ?',
      [documentId],
    ));
    return count ?? 0;
  }

  /// Gets context cards for a chunk sequence range.
  Future<List<Map<String, dynamic>>> getCardsForWindow(
    String documentId, {
    int startSequence = 0,
    int endSequence = 1000000,
  }) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      '''
      SELECT c.*
      FROM context_cards c
      LEFT JOIN reading_chunks rc ON rc.id = c.source_chunk_id
      WHERE c.document_id = ? AND c.dismissed = 0
        AND (rc.sequence IS NULL OR (rc.sequence >= ? AND rc.sequence <= ?))
      ORDER BY rc.sequence ASC
      ''',
      [documentId, startSequence, endSequence],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Persists canonical reading position: (document_id, chunk_seq, intra_byte, updated_at).
  Future<void> saveReadingPosition(
    String documentId, {
    required int chunkSeq,
    int intraByte = 0,
    String? chunkId,
  }) async {
    await _db.updateReadingPosition(
      documentId,
      chunkIndex: chunkSeq,
      chunkId: chunkId,
      chunkSeq: chunkSeq,
      intraByte: intraByte,
    );
  }

  /// Retrieves canonical reading position: (chunkSeq, intraByte, updatedAt).
  Future<({int chunkSeq, int intraByte, String updatedAt})?> getReadingPosition(
    String documentId,
  ) async {
    return _db.getReadingPosition(documentId);
  }
}

class _LruChunkCache {
  final int capacity;
  final LinkedHashMap<int, Map<String, dynamic>> _cache = LinkedHashMap();

  _LruChunkCache(this.capacity);

  Map<String, dynamic>? get(int sequence) {
    final val = _cache.remove(sequence);
    if (val != null) {
      _cache[sequence] = val;
    }
    return val;
  }

  void put(int sequence, Map<String, dynamic> chunk) {
    _cache.remove(sequence);
    if (_cache.length >= capacity) {
      _cache.remove(_cache.keys.first);
    }
    _cache[sequence] = chunk;
  }

  void clear() => _cache.clear();
}
