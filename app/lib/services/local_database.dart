import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documentsDir.path, 'athena_library.sqlite');
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
          await db.execute(
            'CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts USING fts5('
            'chunk_id UNINDEXED, document_id UNINDEXED, raw_text, section_title, tokenize=\'unicode61\')'
          );
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
      },
    );
  }

  Future<List<Map<String, dynamic>>> listDocuments() async {
    final db = await database;
    final rows = await db.query('documents', where: "status != 'deleted'", orderBy: 'created_at DESC');
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
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final c in chunks) {
        batch.insert('reading_chunks', c,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);

      try {
        final ftsBatch = txn.batch();
        for (final c in chunks) {
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
  }

  Future<List<Map<String, dynamic>>> searchChunks(
    String documentId,
    String query, {
    int limit = 20,
  }) async {
    final db = await database;
    final qClean = query.trim();
    if (qClean.isEmpty) return [];

    try {
      final ftsRows = await db.rawQuery('''
        SELECT c.*, bm25(reading_chunks_fts) as rank
        FROM reading_chunks_fts f
        JOIN reading_chunks c ON c.id = f.chunk_id
        WHERE f.document_id = ? AND reading_chunks_fts MATCH ?
        ORDER BY rank ASC LIMIT ?
      ''', [documentId, '$qClean*', limit]);
      if (ftsRows.isNotEmpty) {
        return ftsRows.map((r) => Map<String, dynamic>.from(r)).toList();
      }
    } catch (e) {
      debugPrint('Athena FTS5 search query notice: $e');
    }

    final rows = await db.query(
      'reading_chunks',
      where: 'document_id = ? AND raw_text LIKE ?',
      whereArgs: [documentId, '%$qClean%'],
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<void> insertCards(List<Map<String, Object?>> cards) async {
    final db = await database;
    final batch = db.batch();
    for (final c in cards) {
      batch.insert('context_cards', c,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteDocument(String id) async {
    final db = await database;
    final savedCards = await db.query('context_cards',
        where: 'document_id = ? AND saved = 1', whereArgs: [id]);
    await db.delete('reading_chunks', where: 'document_id = ?', whereArgs: [id]);
    await db.delete('document_pages', where: 'document_id = ?', whereArgs: [id]);
    if (savedCards.isNotEmpty) {
      await db.delete('context_cards',
          where: 'document_id = ? AND saved = 0', whereArgs: [id]);
      await db.update('documents', {
        'status': 'deleted',
        'file_path': '',
        'canonical_text': '',
      }, where: 'id = ?', whereArgs: [id]);
    } else {
      await db.delete('context_cards', where: 'document_id = ?', whereArgs: [id]);
      await db.delete('documents', where: 'id = ?', whereArgs: [id]);
    }
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
    final cardRows = await db.query('context_cards',
        where: 'document_id = ? AND dismissed = 0', whereArgs: [documentId]);

    final chunks = chunkRows.map((r) => Map<String, dynamic>.from(r)).toList();
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
          'sequence': chunk['sequence'],
          'concept_name': card['concept_name'],
          'card_type': card['card_type'] ?? 'context',
          'title': card['title'] ?? '',
          'body': card['body'] ?? '',
          'why_here': card['why_here'] ?? '',
          'exact_quote': card['exact_quote'],
          'support_status': card['support_status'] ?? 'fully_supported',
          'generation_mode': card['generation_mode'] ?? 'grounded',
          'saved': card['saved'] == 1,
          'citations': citations,
        });
      }
    }

    // Interleave any remaining unassigned cards every 3 chunks so no card is orphaned
    final unassigned = cards.where((c) => !assignedCardIds.contains(c['id'])).toList();
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
                citations = jsonDecode(card['citations_json'] as String) as List;
              } catch (e) {
        debugPrint('Athena caught error: $e');
      }
            }
            items.insert(i + 1, {
              'type': 'context_card',
              'id': card['id'],
              'insert_after': items[i]['id'],
              'sequence': seq,
              'concept_name': card['concept_name'],
              'card_type': card['card_type'] ?? 'context',
              'title': card['title'] ?? '',
              'body': card['body'] ?? '',
              'why_here': card['why_here'] ?? '',
              'exact_quote': card['exact_quote'],
              'support_status': card['support_status'] ?? 'fully_supported',
              'generation_mode': card['generation_mode'] ?? 'grounded',
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
}
