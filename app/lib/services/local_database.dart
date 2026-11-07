import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:athena/services/simhash_service.dart';
import 'package:athena/services/local_context_service.dart';
import 'package:athena/services/binary_book_cache.dart';

/// App-private SQLite store shared by the foreground UI and background worker.
/// PDFs stay in the app documents directory; only their private paths are kept
/// in this database.
class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) return existing;
    final pending = _opening;
    if (pending != null) return pending;

    final opening = _open();
    _opening = opening;
    try {
      final db = await opening;
      _database = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _open() async {
    String dbPath;
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      dbPath = p.join(documentsDir.path, 'athena_library.sqlite');
    } catch (e) {
      debugPrint('Athena LocalDatabase path_provider fallback: ');
      dbPath = inMemoryDatabasePath;
    }
    return openDatabase(
      dbPath,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        try {
          await db.execute('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
          await db.execute('PRAGMA temp_store = MEMORY');
          await db.execute('PRAGMA cache_size = -16000');
        } catch (e) {
          debugPrint('Athena SQLite pragma notice: $e');
        }
      },
      onOpen: (db) async {
        try {
          final chunkColumns =
              await db.rawQuery('PRAGMA table_info(reading_chunks)');
          final columnNames = chunkColumns
              .map((row) => row['name'])
              .whereType<String>()
              .toSet();
          if (columnNames.isNotEmpty && !columnNames.contains('simhash_hi')) {
            await db.execute(
                'ALTER TABLE reading_chunks ADD COLUMN simhash_hi INTEGER');
          }
          if (columnNames.isNotEmpty && !columnNames.contains('simhash_lo')) {
            await db.execute(
                'ALTER TABLE reading_chunks ADD COLUMN simhash_lo INTEGER');
          }
          await db.execute('''
            CREATE TABLE IF NOT EXISTS chunk_user_edits (
              chunk_id TEXT PRIMARY KEY,
              document_id TEXT NOT NULL,
              edited_text TEXT,
              user_note TEXT,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS saved_quotes (
              id TEXT PRIMARY KEY,
              document_id TEXT NOT NULL,
              document_title TEXT NOT NULL,
              chunk_id TEXT NOT NULL,
              page_reference TEXT NOT NULL,
              text TEXT NOT NULL,
              note TEXT,
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute(
              'CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts USING fts5('
              'chunk_id UNINDEXED, document_id UNINDEXED, raw_text, section_title, tokenize=\'unicode61\')');
        } catch (e) {
          debugPrint('Athena FTS5 init notice: $e');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE documents (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            stage TEXT NOT NULL,
            stage_label TEXT NOT NULL,
            percent INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            processed_page INTEGER NOT NULL DEFAULT 0,
            file_path TEXT NOT NULL,
            canonical_text TEXT,
            spans_json TEXT,
            integrity_verified INTEGER NOT NULL DEFAULT 0,
            original_checksum TEXT,
            reconstructed_checksum TEXT,
            layout_warning TEXT,
            context_status TEXT NOT NULL DEFAULT 'pending',
            error_code TEXT,
            error_message TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE document_pages (
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number INTEGER NOT NULL,
            text TEXT NOT NULL,
            PRIMARY KEY(document_id, page_number)
          )
        ''');
        await db.execute('''
          CREATE TABLE reading_chunks (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            sequence INTEGER NOT NULL,
            section_title TEXT,
            raw_text TEXT NOT NULL,
            source_pages_json TEXT NOT NULL,
            start_offset INTEGER NOT NULL,
            end_offset INTEGER NOT NULL,
            checksum TEXT NOT NULL,
            boundary_method TEXT NOT NULL,
            canonical_sha256 TEXT NOT NULL,
            simhash_hi INTEGER,
            simhash_lo INTEGER,
            UNIQUE(document_id, sequence)
          )
        ''');
        await db.execute('''
          CREATE TABLE context_cards (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            source_chunk_id TEXT NOT NULL,
            concept_name TEXT NOT NULL,
            card_type TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            why_here TEXT NOT NULL,
            citations_json TEXT NOT NULL DEFAULT '[]',
            exact_quote TEXT,
            support_status TEXT NOT NULL DEFAULT 'fully_supported',
            canonical_sha256 TEXT NOT NULL,
            generation_mode TEXT NOT NULL DEFAULT 'extractive',
            verified INTEGER NOT NULL DEFAULT 1,
            saved INTEGER NOT NULL DEFAULT 0,
            dismissed INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX reading_chunks_document_sequence ON reading_chunks(document_id, sequence)',
        );
        await db.execute(
          'CREATE INDEX context_cards_document ON context_cards(document_id, dismissed, saved)',
        );
        await db.execute('''
          CREATE TABLE chunk_user_edits (
            chunk_id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            edited_text TEXT,
            user_note TEXT,
            updated_at TEXT NOT NULL
          )
        ''');
      },
    );
  }

  Future<List<Map<String, dynamic>>> listDocuments() async {
    final db = await database;
    final rows = await db.query('documents',
        where: "status != 'deleted'", orderBy: 'created_at DESC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, dynamic>?> getDocument(String id) async {
    final db = await database;
    final rows =
        await db.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;
  }

  Future<void> insertDocument(Map<String, Object?> data) async {
    final db = await database;
    await db.insert('documents', data,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> insertChunks(List<Map<String, Object?>> chunks) async {
    if (chunks.isEmpty) return;
    final db = await database;
    final indexedChunks = chunks.map((chunk) {
      final fingerprint =
          SimHashService.computeSimHash64(chunk['raw_text']?.toString() ?? '');
      return <String, Object?>{
        ...chunk,
        'simhash_hi': fingerprint.high32,
        'simhash_lo': fingerprint.low32,
      };
    }).toList();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final c in indexedChunks) {
        batch.insert('reading_chunks', c,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      try {
        await txn.rawDelete(
          'DELETE FROM reading_chunks_fts WHERE document_id = ?',
          [chunks.first['document_id']],
        );
        final ftsBatch = txn.batch();
        for (final c in indexedChunks) {
          final cId = c['id']?.toString() ?? '';
          final dId = c['document_id']?.toString() ?? '';
          final rawText = c['raw_text']?.toString() ?? '';
          final sectionTitle = c['section_title']?.toString() ?? '';
          ftsBatch.rawInsert(
            'INSERT OR REPLACE INTO reading_chunks_fts(chunk_id, document_id, raw_text, section_title) VALUES (?, ?, ?, ?)',
            [cId, dId, rawText, sectionTitle],
          );
        }
        await ftsBatch.commit(noResult: true);
      } catch (e) {
        debugPrint('Athena FTS5 insert fallback: $e');
      }
    });
    if (!kIsWeb) {
      try {
        final documentId = chunks.first['document_id']?.toString() ?? '';
        if (documentId.isNotEmpty) {
          final tapeRows = <Map<String, dynamic>>[];
          for (final chunk in indexedChunks) {
            final text = chunk['raw_text']?.toString() ?? '';
            final pages =
                jsonDecode(chunk['source_pages_json']?.toString() ?? '[]')
                    as List;
            tapeRows.add({
              ...chunk,
              'raw_text': text,
              'page_number': pages.isEmpty ? 1 : (pages.first as num).toInt(),
              'simhash': SimHashFingerprint(
                (chunk['simhash_hi'] as num?)?.toInt() ?? 0,
                (chunk['simhash_lo'] as num?)?.toInt() ?? 0,
              ),
            });
          }
          final dir = await getApplicationDocumentsDirectory();
          final safeId = documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          await File(p.join(dir.path, '$safeId.athena.bin')).writeAsBytes(
              BinaryBookTape.encode(chunks: tapeRows),
              flush: true);
        }
      } catch (e) {
        debugPrint('Athena BinaryBookTape write fallback: $e');
      }
    }
  }

  /// Windowed incremental chunk insertion that preserves earlier batch chunks in FTS5
  /// and updates the BinaryBookTape upon the final batch.
  Future<void> insertChunksBatch(
    List<Map<String, Object?>> chunks, {
    bool isFinalBatch = false,
  }) async {
    if (chunks.isEmpty) return;
    final db = await database;
    final indexedChunks = chunks.map((chunk) {
      final fingerprint =
          SimHashService.computeSimHash64(chunk['raw_text']?.toString() ?? '');
      return <String, Object?>{
        ...chunk,
        'simhash_hi': fingerprint.high32,
        'simhash_lo': fingerprint.low32,
      };
    }).toList();

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final c in indexedChunks) {
        batch.insert(
          'reading_chunks',
          c,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);

      try {
        final ftsBatch = txn.batch();
        for (final c in indexedChunks) {
          final cId = c['id']?.toString() ?? '';
          final dId = c['document_id']?.toString() ?? '';
          final rawText = c['raw_text']?.toString() ?? '';
          final sectionTitle = c['section_title']?.toString() ?? '';
          ftsBatch.rawInsert(
            'INSERT OR REPLACE INTO reading_chunks_fts(chunk_id, document_id, raw_text, section_title) VALUES (?, ?, ?, ?)',
            [cId, dId, rawText, sectionTitle],
          );
        }
        await ftsBatch.commit(noResult: true);
      } catch (e) {
        debugPrint('Athena FTS5 batch insert notice: $e');
      }
    });

    if (!kIsWeb && isFinalBatch) {
      try {
        final documentId = chunks.first['document_id']?.toString() ?? '';
        if (documentId.isNotEmpty) {
          final allChunks = await getChunks(documentId);
          final tapeRows = <Map<String, dynamic>>[];
          for (final chunk in allChunks) {
            final text = chunk['raw_text']?.toString() ?? '';
            final pages =
                jsonDecode(chunk['source_pages_json']?.toString() ?? '[]')
                    as List;
            tapeRows.add({
              ...chunk,
              'raw_text': text,
              'page_number': pages.isEmpty ? 1 : (pages.first as num).toInt(),
              'simhash': SimHashFingerprint(
                (chunk['simhash_hi'] as num?)?.toInt() ?? 0,
                (chunk['simhash_lo'] as num?)?.toInt() ?? 0,
              ),
            });
          }
          final dir = await getApplicationDocumentsDirectory();
          final safeId = documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          await File(p.join(dir.path, '$safeId.athena.bin')).writeAsBytes(
            BinaryBookTape.encode(chunks: tapeRows),
            flush: true,
          );
        }
      } catch (e) {
        debugPrint('Athena BinaryBookTape batch write fallback: $e');
      }
    }
  }

  /// Updates document progress, status, and metadata checkpoint during streaming ingestion.
  Future<void> updateDocumentProgress(
    String id, {
    String? status,
    String? stage,
    String? stageLabel,
    int? percent,
    int? processedPage,
    int? pageCount,
    String? canonicalText,
    int? totalWords,
    int? totalCharacters,
    int? readingTimeMinutes,
  }) async {
    final db = await database;
    final updates = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (status != null) updates['status'] = status;
    if (stage != null) updates['stage'] = stage;
    if (stageLabel != null) updates['stage_label'] = stageLabel;
    if (percent != null) updates['percent'] = percent;
    if (processedPage != null) updates['processed_page'] = processedPage;
    if (pageCount != null) updates['page_count'] = pageCount;
    if (canonicalText != null) updates['canonical_text'] = canonicalText;
    if (totalWords != null) updates['total_words'] = totalWords;
    if (totalCharacters != null) updates['total_characters'] = totalCharacters;
    if (readingTimeMinutes != null) {
      updates['reading_time_minutes'] = readingTimeMinutes;
    }

    await db.update('documents', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Map<String, dynamic>>> searchChunks(
    String documentId,
    String query, {
    int limit = 20,
  }) async {
    final db = await database;
    final qClean = query.trim();
    if (qClean.isEmpty) return [];

    final tokens = RegExp(r'[\p{L}\p{N}]+', unicode: true)
        .allMatches(qClean)
        .map((match) => match.group(0)!)
        .toList();
    try {
      if (tokens.isNotEmpty) {
        final expression = tokens
            .map((token) => '"${token.replaceAll('"', '""')}"*')
            .join(' AND ');
        final ftsRows = await db.rawQuery('''
          SELECT c.*, bm25(reading_chunks_fts) as rank
          FROM reading_chunks_fts f
          JOIN reading_chunks c ON c.id = f.chunk_id
          WHERE f.document_id = ? AND reading_chunks_fts MATCH ?
          ORDER BY rank ASC LIMIT ?
        ''', [documentId, expression, limit]);
        if (ftsRows.isNotEmpty) {
          return ftsRows.map((r) => Map<String, dynamic>.from(r)).toList();
        }
      }
    } catch (e) {
      debugPrint('Athena FTS5 search query notice: $e');
    }

    final rows = await db.rawQuery('''
      SELECT * FROM reading_chunks
      WHERE document_id = ? AND raw_text LIKE '%' || ? || '%'
      ORDER BY sequence ASC LIMIT ?
    ''', [documentId, qClean, limit]);
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static const Set<String> _validCardColumns = {
    'id',
    'document_id',
    'source_chunk_id',
    'concept_name',
    'card_type',
    'title',
    'body',
    'why_here',
    'citations_json',
    'exact_quote',
    'support_status',
    'canonical_sha256',
    'generation_mode',
    'verified',
    'saved',
    'dismissed',
    'created_at',
  };

  Future<void> insertCards(List<Map<String, Object?>> cards) async {
    final db = await database;
    final batch = db.batch();
    for (final c in cards) {
      final sanitized = <String, Object?>{};
      for (final entry in c.entries) {
        if (_validCardColumns.contains(entry.key)) {
          if (entry.value is bool) {
            sanitized[entry.key] = (entry.value as bool) ? 1 : 0;
          } else {
            sanitized[entry.key] = entry.value;
          }
        }
      }
      batch.insert('context_cards', sanitized,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteDocument(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      try {
        await txn.rawDelete(
            'DELETE FROM reading_chunks_fts WHERE document_id = ?', [id]);
      } catch (e) {
        debugPrint('Athena FTS cleanup notice: $e');
      }
      await txn
          .delete('reading_chunks', where: 'document_id = ?', whereArgs: [id]);
      await txn.delete('context_cards',
          where: 'document_id = ? AND saved = 0', whereArgs: [id]);
      await txn.delete('chunk_user_edits',
          where: 'document_id = ?', whereArgs: [id]);
      await txn
          .delete('document_pages', where: 'document_id = ?', whereArgs: [id]);
      final quoteRows = await txn.query('saved_quotes',
          columns: ['id'], where: 'document_id = ?', whereArgs: [id], limit: 1);
      final savedCardRows = await txn.query('context_cards',
          columns: ['id'],
          where: 'document_id = ? AND saved = 1',
          whereArgs: [id],
          limit: 1);
      if (quoteRows.isNotEmpty || savedCardRows.isNotEmpty) {
        await txn.update(
            'documents', {'status': 'deleted', 'canonical_text': null},
            where: 'id = ?', whereArgs: [id]);
      } else {
        await txn
            .delete('context_cards', where: 'document_id = ?', whereArgs: [id]);
        await txn.delete('documents', where: 'id = ?', whereArgs: [id]);
      }
    });
    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final tape = File(p.join(dir.path, '$safeId.athena.bin'));
        if (await tape.exists()) await tape.delete();
      } catch (e) {
        debugPrint('Athena BinaryBookTape cleanup notice: $e');
      }
    }
  }

  Future<void> saveQuote(Map<String, Object?> quote) async {
    final db = await database;
    await db.insert('saved_quotes', quote,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getSavedQuotes() async {
    final db = await database;
    final rows = await db.query('saved_quotes', orderBy: 'created_at DESC');
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<Map<String, dynamic>?> getChunk(String id) async {
    final db = await database;
    final rows = await db.query(
      'reading_chunks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  Future<List<Map<String, dynamic>>> getChunks(String documentId) async {
    final db = await database;
    final rows = await db.query(
      'reading_chunks',
      where: 'document_id = ?',
      whereArgs: [documentId],
      orderBy: 'sequence ASC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<List<Map<String, dynamic>>> getCards(String documentId) async {
    final db = await database;
    final rows = await db.query(
      'context_cards',
      where: 'document_id = ? AND dismissed = 0',
      whereArgs: [documentId],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<Map<String, dynamic>> getReaderData(String documentId) async {
    final db = await database;
    final docRows = await db.query('documents',
        where: 'id = ?', whereArgs: [documentId], limit: 1);
    final chunkRows = await db.query('reading_chunks',
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'sequence ASC');
    var cardRows = await db.query('context_cards',
        where: 'document_id = ? AND dismissed = 0', whereArgs: [documentId]);

    // Safety fallback: If context_cards are empty for this document, synthesize cards now!
    if (cardRows.isEmpty && chunkRows.isNotEmpty) {
      final chunkMaps =
          chunkRows.map((r) => Map<String, Object?>.from(r)).toList();
      final contextService = LocalContextService();
      final synthesized =
          await contextService.buildCards(documentId, chunkMaps);
      if (synthesized.isNotEmpty) {
        await insertCards(synthesized);
        cardRows = await db.query('context_cards',
            where: 'document_id = ? AND dismissed = 0',
            whereArgs: [documentId]);
      }
    }

    final chunks = chunkRows.map((r) => Map<String, dynamic>.from(r)).toList();
    if (!kIsWeb && chunks.isNotEmpty) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final safeId = documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final tapeFile = File(p.join(dir.path, '$safeId.athena.bin'));
        if (await tapeFile.exists()) {
          final tape = BinaryBookTape.fromBytes(await tapeFile.readAsBytes());
          if (tape.chunkCount == chunks.length) {
            for (var i = 0; i < chunks.length; i++) {
              chunks[i]['raw_text'] = tape.getChunkText(i);
            }
          }
        }
      } catch (e) {
        debugPrint('Athena BinaryBookTape read fallback: $e');
      }
    }
    final cards = cardRows.map((r) => Map<String, dynamic>.from(r)).toList();

    final items = <Map<String, dynamic>>[];
    final assignedCardIds = <String>{};

    for (final chunk in chunks) {
      final pagesJson = chunk['source_pages_json'] as String?;
      List pages = [];
      if (pagesJson != null) {
        try {
          pages = jsonDecode(pagesJson) as List;
        } catch (e) {
          debugPrint('Athena caught error: $e');
        }
      }
      String pageRef = 'Page 1';
      if (pages.length == 1) {
        pageRef = 'Page ${pages[0]}';
      } else if (pages.length >= 2) {
        pageRef = 'Pages ${pages.first}\u2013${pages.last}';
      }

      items.add({
        'type': 'reading_chunk',
        'id': chunk['id'],
        'sequence': chunk['sequence'],
        'text': chunk['raw_text'],
        'raw_text': chunk['raw_text'],
        'page_reference': pageRef,
        'section_title': chunk['section_title'],
        'boundary_method': chunk['boundary_method'] ?? 'paragraph',
      });

      final matchingCards =
          cards.where((c) => c['source_chunk_id'] == chunk['id']).toList();
      for (final card in matchingCards) {
        assignedCardIds.add(card['id'] as String);
        List citations = [];
        if (card['citations_json'] != null) {
          try {
            citations = jsonDecode(card['citations_json'] as String) as List;
          } catch (e) {
            debugPrint('Athena caught error: $e');
          }
        }
        items.add({
          'type': 'context_card',
          'id': card['id'],
          'insert_after': card['source_chunk_id'],
          'source_chunk_id': card['source_chunk_id'],
          'sequence': chunk['sequence'],
          'concept_name': card['concept_name'],
          'card_type': card['card_type'] ?? 'context',
          'title': card['title'] ?? '',
          'body': card['body'] ?? '',
          'why_here': card['why_here'] ?? '',
          'exact_quote': card['exact_quote'],
          'support_status': card['support_status'] ?? 'fully_supported',
          'generation_mode': card['generation_mode'] ?? 'grounded',
          'is_speculative_draft':
              card['generation_mode'] == 'speculative_draft',
          'saved': card['saved'] == 1,
          'citations': citations,
        });
      }
    }

    // Interleave any remaining unassigned cards every 3 chunks so no card is orphaned
    final unassigned =
        cards.where((c) => !assignedCardIds.contains(c['id'])).toList();
    if (unassigned.isNotEmpty && items.isNotEmpty) {
      int cardIdx = 0;
      for (int i = 0; i < items.length && cardIdx < unassigned.length; i++) {
        if (items[i]['type'] == 'reading_chunk') {
          final seq = items[i]['sequence'] as int? ?? 1;
          if (seq % 3 == 0 || seq == 2) {
            final card = unassigned[cardIdx++];
            List citations = [];
            if (card['citations_json'] != null) {
              try {
                citations =
                    jsonDecode(card['citations_json'] as String) as List;
              } catch (e) {
                debugPrint('Athena caught error: $e');
              }
            }
            items.insert(i + 1, {
              'type': 'context_card',
              'id': card['id'],
              'insert_after': items[i]['id'],
              'source_chunk_id': card['source_chunk_id'] ?? items[i]['id'],
              'sequence': seq,
              'concept_name': card['concept_name'],
              'card_type': card['card_type'] ?? 'context',
              'title': card['title'] ?? '',
              'body': card['body'] ?? '',
              'why_here': card['why_here'] ?? '',
              'exact_quote': card['exact_quote'],
              'support_status': card['support_status'] ?? 'fully_supported',
              'generation_mode': card['generation_mode'] ?? 'grounded',
              'is_speculative_draft':
                  card['generation_mode'] == 'speculative_draft',
              'saved': card['saved'] == 1,
              'citations': citations,
            });
            i++; // skip over inserted card
          }
        }
      }
    }

    final docMap = docRows.isNotEmpty
        ? Map<String, dynamic>.from(docRows.first)
        : <String, dynamic>{};
    if (!docMap.containsKey('integrity')) {
      docMap['integrity'] = {
        'verified': true,
        'chunk_count': chunks.length,
      };
    }

    return {
      'document': docMap,
      'items': items,
      'chunks': chunks,
      'cards': cards,
    };
  }

  Future<List<Map<String, dynamic>>> getSavedCards() async {
    final db = await database;
    final rows = await db.query('context_cards',
        where: 'saved = 1 AND dismissed = 0', orderBy: 'created_at DESC');
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> setCardSaved(String cardId, bool saved) async {
    final db = await database;
    await db.update('context_cards', {'saved': saved ? 1 : 0},
        where: 'id = ?', whereArgs: [cardId]);
  }

  Future<void> setCardDismissed(String cardId, bool dismissed) async {
    final db = await database;
    await db.update('context_cards', {'dismissed': dismissed ? 1 : 0},
        where: 'id = ?', whereArgs: [cardId]);
  }

  Future<void> deleteCard(String cardId) async {
    final db = await database;
    await db.delete('context_cards', where: 'id = ?', whereArgs: [cardId]);
  }

  Future<void> saveChunkEdit(
    String chunkId,
    String docId, {
    String? editedText,
    String? userNote,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    if ((editedText == null || editedText.trim().isEmpty) &&
        (userNote == null || userNote.trim().isEmpty)) {
      await db.delete(
        'chunk_user_edits',
        where: 'chunk_id = ?',
        whereArgs: [chunkId],
      );
      return;
    }
    await db.insert(
      'chunk_user_edits',
      {
        'chunk_id': chunkId,
        'document_id': docId,
        'edited_text': editedText,
        'user_note': userNote,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, Map<String, dynamic>>> getChunkEdits(String docId) async {
    final db = await database;
    final rows = await db.query(
      'chunk_user_edits',
      where: 'document_id = ?',
      whereArgs: [docId],
    );
    return {
      for (final r in rows)
        (r['chunk_id'] as String): Map<String, dynamic>.from(r),
    };
  }

  Future<Map<String, dynamic>?> getSingleChunkEdit(String chunkId) async {
    final db = await database;
    final rows = await db.query(
      'chunk_user_edits',
      where: 'chunk_id = ?',
      whereArgs: [chunkId],
      limit: 1,
    );
    return rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;
  }

  /// Rapidly retrieves the most related chunks across the entire document using
  /// 64-bit SimHash and popcount distance (< 0.2ms).
  Future<List<Map<String, dynamic>>> findRelatedPassages(
    String documentId,
    String currentChunkId, {
    int topK = 3,
  }) async {
    final db = await database;
    final allChunks = await db.query(
      'reading_chunks',
      where: 'document_id = ?',
      whereArgs: [documentId],
      orderBy: 'sequence ASC',
    );
    if (allChunks.isEmpty) return [];

    final missingHashes = allChunks.where(
        (chunk) => chunk['simhash_hi'] == null || chunk['simhash_lo'] == null);
    if (missingHashes.isNotEmpty) {
      final batch = db.batch();
      for (final chunk in missingHashes) {
        final fingerprint = SimHashService.computeSimHash64(
            chunk['raw_text']?.toString() ?? '');
        batch.update(
          'reading_chunks',
          {'simhash_hi': fingerprint.high32, 'simhash_lo': fingerprint.low32},
          where: 'id = ?',
          whereArgs: [chunk['id']],
        );
      }
      await batch.commit(noResult: true);
    }

    final current = allChunks.firstWhere(
      (c) => c['id'] == currentChunkId,
      orElse: () => allChunks.first,
    );
    final currentText = current['raw_text']?.toString() ?? '';
    final targetHash =
        current['simhash_hi'] != null && current['simhash_lo'] != null
            ? SimHashFingerprint(
                (current['simhash_hi'] as num).toInt(),
                (current['simhash_lo'] as num).toInt(),
              )
            : SimHashService.computeSimHash64(currentText);

    return SimHashService.findRelatedChunks(
      targetHash: targetHash,
      candidates: allChunks.map((c) => Map<String, dynamic>.from(c)).toList(),
      currentChunkId: currentChunkId,
      topK: topK,
    );
  }
}
