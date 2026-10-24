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
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
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
    final rows = await db.query('documents', orderBy: 'created_at DESC');
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
    final batch = db.batch();
    for (final c in chunks) {
      batch.insert('reading_chunks', c,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
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
    await db.delete('documents', where: 'id = ?', whereArgs: [id]);
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
    return {
      'document': docRows.isNotEmpty
          ? Map<String, dynamic>.from(docRows.first)
          : <String, dynamic>{},
      'chunks': chunkRows.map((r) => Map<String, dynamic>.from(r)).toList(),
      'cards': cardRows.map((r) => Map<String, dynamic>.from(r)).toList(),
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
