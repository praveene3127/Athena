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
      version: 3,
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
      onUpgrade: (db, oldVersion, newVersion) async {
        try {
          final docCols = (await db.rawQuery('PRAGMA table_info(documents)'))
              .map((r) => r['name'])
              .whereType<String>()
              .toSet();
          if (docCols.isNotEmpty) {
            for (final col in [
              ('cards_generated', 'INTEGER DEFAULT 0'),
              ('current_chunk_index', 'INTEGER DEFAULT 0'),
              ('current_chunk_id', 'TEXT'),
              ('reading_mode', "TEXT DEFAULT 'feed'"),
              ('author', "TEXT DEFAULT ''"),
              ('format', "TEXT DEFAULT ''"),
              ('processed_pages', 'INTEGER DEFAULT 0'),
              ('chunk_count', 'INTEGER DEFAULT 0'),
              ('total_words', 'INTEGER DEFAULT 0'),
              ('total_characters', 'INTEGER DEFAULT 0'),
              ('reading_time_minutes', 'INTEGER DEFAULT 0'),
            ]) {
              if (!docCols.contains(col.$1)) {
                await db.execute('ALTER TABLE documents ADD COLUMN ${col.$1} ${col.$2}');
              }
            }
          }

          final chunkCols = (await db.rawQuery('PRAGMA table_info(reading_chunks)'))
              .map((r) => r['name'])
              .whereType<String>()
              .toSet();
          if (chunkCols.isNotEmpty) {
            if (!chunkCols.contains('simhash_hi')) {
              await db.execute('ALTER TABLE reading_chunks ADD COLUMN simhash_hi INTEGER');
            }
            if (!chunkCols.contains('simhash_lo')) {
              await db.execute('ALTER TABLE reading_chunks ADD COLUMN simhash_lo INTEGER');
            }
            if (!chunkCols.contains('section_role')) {
              await db.execute("ALTER TABLE reading_chunks ADD COLUMN section_role TEXT DEFAULT 'chapter'");
            }
          }

          final cardCols = (await db.rawQuery('PRAGMA table_info(context_cards)'))
              .map((r) => r['name'])
              .whereType<String>()
              .toSet();
          if (cardCols.isNotEmpty && !cardCols.contains('support_tier')) {
            await db.execute("ALTER TABLE context_cards ADD COLUMN support_tier TEXT DEFAULT 'verified_external'");
          }
        } catch (e) {
          debugPrint('Athena SQLite upgrade notice: $e');
        }
      },
      onOpen: (db) async {
        try {
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
          await db.execute('''
            CREATE TABLE IF NOT EXISTS academic_evidence_cache (
              query_key TEXT PRIMARY KEY,
              json_payload TEXT,
              created_at INTEGER
            )
          ''');
          try {
            await db.execute(
                'CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts USING fts5('
                'chunk_id UNINDEXED, document_id UNINDEXED, raw_text, section_title, tokenize=\'unicode61\')');
          } catch (e) {
            debugPrint('[Athena LocalDatabase] FTS5 init notice: $e');
            try {
              await db.execute(
                  'CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts USING fts4('
                  'chunk_id, document_id, raw_text, section_title)');
            } catch (e2) {
              debugPrint('[Athena LocalDatabase] FTS4 init notice: $e2');
            }
          }
        } catch (e) {
          debugPrint('Athena DB init notice: $e');
        }
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE documents (
            id TEXT PRIMARY KEY,
            filename TEXT NOT NULL,
            title TEXT NOT NULL,
            author TEXT DEFAULT '',
            format TEXT DEFAULT '',
            status TEXT NOT NULL,
            stage TEXT NOT NULL,
            stage_label TEXT NOT NULL,
            percent INTEGER NOT NULL DEFAULT 0,
            page_count INTEGER NOT NULL DEFAULT 0,
            processed_page INTEGER NOT NULL DEFAULT 0,
            processed_pages INTEGER NOT NULL DEFAULT 0,
            chunk_count INTEGER NOT NULL DEFAULT 0,
            file_path TEXT NOT NULL,
            canonical_text TEXT,
            spans_json TEXT,
            integrity_verified INTEGER NOT NULL DEFAULT 0,
            original_checksum TEXT,
            reconstructed_checksum TEXT,
            total_words INTEGER DEFAULT 0,
            total_characters INTEGER DEFAULT 0,
            reading_time_minutes INTEGER DEFAULT 0,
            current_chunk_index INTEGER DEFAULT 0,
            current_chunk_id TEXT,
            reading_mode TEXT DEFAULT 'feed',
            cards_generated INTEGER DEFAULT 0,
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
            section_role TEXT DEFAULT 'chapter',
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
            support_status TEXT NOT NULL DEFAULT 'unverified',
            support_tier TEXT NOT NULL DEFAULT 'verified_external',
            canonical_sha256 TEXT NOT NULL,
            generation_mode TEXT NOT NULL DEFAULT 'extractive',
            verified INTEGER NOT NULL DEFAULT 0,
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
        await db.execute('''
          CREATE TABLE academic_evidence_cache (
            query_key TEXT PRIMARY KEY,
            json_payload TEXT,
            created_at INTEGER
          )
        ''');
      },
    );
  }

  static const List<String> documentListColumns = [
    'id',
    'title',
    'filename',
    'author',
    'file_path',
    'format',
    'status',
    'stage',
    'stage_label',
    'percent',
    'page_count',
    'processed_page',
    'processed_pages',
    'chunk_count',
    'current_chunk_index',
    'current_chunk_id',
    'reading_mode',
    'cards_generated',
    'layout_warning',
    'context_status',
    'error_code',
    'error_message',
    'integrity_verified',
    'created_at',
    'updated_at',
  ];

  Future<List<Map<String, dynamic>>> listDocuments() async {
    final db = await database;
    final rows = await db.query(
      'documents',
      columns: documentListColumns,
      where: "status != 'deleted'",
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  Future<int> recoverStaleProcessingDocuments() async {
    final db = await database;
    return await db.update(
      'documents',
      {
        'status': 'failed',
        'error_code': 'EXTRACTION_INTERRUPTED',
        'error_message': 'Extraction was interrupted when the app was closed.',
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: "status = 'processing' OR status = 'queued'",
    );
  }

  Future<Map<String, dynamic>?> getDocumentStatus(String id) async {
    final doc = await getDocument(id);
    if (doc == null) return null;
    return {
      'document_id': id,
      'status': doc['status'] ?? 'ready',
      'stage': doc['stage'] ?? 'done',
      'stage_label': doc['stage_label'] ?? 'Ready to read',
      'percent': doc['percent'] ?? 100,
      if (doc['error_message'] != null)
        'error': {
          'code': doc['error_code'] ?? 'EXTRACTION_FAILED',
          'message': doc['error_message'],
        },
      'context_status': doc['context_status'],
    };
  }

  Future<String?> getCachedAcademicEvidence(String queryKey) async {
    final db = await database;
    final rows = await db.query(
      'academic_evidence_cache',
      columns: ['json_payload'],
      where: 'query_key = ?',
      whereArgs: [queryKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['json_payload'] as String?;
  }

  Future<void> cacheAcademicEvidence(String queryKey, String jsonPayload) async {
    final db = await database;
    await db.insert(
      'academic_evidence_cache',
      {
        'query_key': queryKey,
        'json_payload': jsonPayload,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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
        final chunkIds = indexedChunks
            .map((c) => c['id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
        final docId = indexedChunks.first['document_id']?.toString() ?? '';
        if (chunkIds.isNotEmpty && docId.isNotEmpty) {
          final placeholders = List.filled(chunkIds.length, '?').join(',');
          await txn.rawDelete(
            'DELETE FROM reading_chunks_fts WHERE document_id = ? AND chunk_id IN ($placeholders)',
            [docId, ...chunkIds],
          );
        }
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
  /// Strict monotonic status transition: once 'ready', status and percent cannot be downgraded.
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
    String? canonicalSha256,
    int? integrityVerified,
    String? errorMessage,
    String? errorCode,
  }) async {
    final db = await database;

    final existing = await db.query(
      'documents',
      columns: ['status', 'percent'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final currentStatus =
        existing.isNotEmpty ? existing.first['status'] as String? : null;
    final currentPercent =
        existing.isNotEmpty ? (existing.first['percent'] as num?)?.toInt() ?? 0 : 0;

    final updates = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
    };

    if (currentStatus == 'ready') {
      // Do not allow downgrade of status or percent once document is ready
      if (status != null && status != 'processing' && status != 'queued') {
        updates['status'] = status;
      }
      if (percent != null && percent >= currentPercent) {
        updates['percent'] = percent;
      }
    } else {
      if (status != null) updates['status'] = status;
      if (percent != null) updates['percent'] = percent;
    }

    if (stage != null) updates['stage'] = stage;
    if (stageLabel != null) updates['stage_label'] = stageLabel;
    if (processedPage != null) {
      updates['processed_page'] = processedPage;
      updates['processed_pages'] = processedPage;
    }
    if (pageCount != null) updates['page_count'] = pageCount;
    if (canonicalText != null) updates['canonical_text'] = canonicalText;
    if (totalWords != null) updates['total_words'] = totalWords;
    if (totalCharacters != null) updates['total_characters'] = totalCharacters;
    if (readingTimeMinutes != null) {
      updates['reading_time_minutes'] = readingTimeMinutes;
    }
    if (canonicalSha256 != null) {
      updates['original_checksum'] = canonicalSha256;
      updates['reconstructed_checksum'] = canonicalSha256;
    }
    if (integrityVerified != null) {
      updates['integrity_verified'] = integrityVerified;
    }
    if (errorMessage != null) updates['error_message'] = errorMessage;
    if (errorCode != null) updates['error_code'] = errorCode;

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
      debugPrint('[Athena LocalDatabase] FTS5 search query notice: $e');
      // FTS4 fallback without bm25
      try {
        if (tokens.isNotEmpty) {
          final expression = tokens
              .map((token) => '"${token.replaceAll('"', '""')}"*')
              .join(' AND ');
          final ftsRows = await db.rawQuery('''
            SELECT c.*
            FROM reading_chunks_fts f
            JOIN reading_chunks c ON c.id = f.chunk_id
            WHERE f.document_id = ? AND reading_chunks_fts MATCH ?
            LIMIT ?
          ''', [documentId, expression, limit]);
          if (ftsRows.isNotEmpty) {
            return ftsRows.map((r) => Map<String, dynamic>.from(r)).toList();
          }
        }
      } catch (e2) {
        debugPrint('[Athena LocalDatabase] FTS4 search query notice: $e2');
      }
    }

    if (tokens.isNotEmpty) {
      final whereClauses = tokens.map((_) => 'LOWER(raw_text) LIKE ?').join(' AND ');
      final whereArgs = <Object?>[
        documentId,
        ...tokens.map((t) => '%${t.toLowerCase()}%'),
        limit,
      ];
      final rows = await db.rawQuery('''
        SELECT * FROM reading_chunks
        WHERE document_id = ? AND $whereClauses
        ORDER BY sequence ASC LIMIT ?
      ''', whereArgs);
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
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
    'support_tier',
    'canonical_sha256',
    'generation_mode',
    'verified',
    'saved',
    'dismissed',
    'created_at',
  };

  Future<void> insertCards(List<Map<String, Object?>> cards) async {
    if (cards.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
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
        final id = sanitized['id']?.toString() ?? '';
        if (id.isEmpty) continue;

        batch.rawInsert('''
          INSERT INTO context_cards (
            id, document_id, source_chunk_id, concept_name, card_type, title, body,
            why_here, citations_json, exact_quote, support_status, support_tier, canonical_sha256,
            generation_mode, verified, saved, dismissed, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            document_id = excluded.document_id,
            source_chunk_id = excluded.source_chunk_id,
            concept_name = excluded.concept_name,
            card_type = excluded.card_type,
            title = excluded.title,
            body = excluded.body,
            why_here = excluded.why_here,
            citations_json = excluded.citations_json,
            exact_quote = excluded.exact_quote,
            support_status = excluded.support_status,
            support_tier = excluded.support_tier,
            canonical_sha256 = excluded.canonical_sha256,
            generation_mode = excluded.generation_mode,
            verified = excluded.verified,
            saved = context_cards.saved,
            dismissed = context_cards.dismissed
        ''', [
          sanitized['id'],
          sanitized['document_id'],
          sanitized['source_chunk_id'],
          sanitized['concept_name'] ?? '',
          sanitized['card_type'] ?? 'context',
          sanitized['title'] ?? '',
          sanitized['body'] ?? '',
          sanitized['why_here'] ?? '',
          sanitized['citations_json'] ?? '[]',
          sanitized['exact_quote'],
          sanitized['support_status'] ?? 'unverified',
          sanitized['support_tier'] ?? 'internal_extractive',
          sanitized['canonical_sha256'] ?? '',
          sanitized['generation_mode'] ?? 'grounded',
          sanitized['verified'] ?? 0,
          sanitized['saved'] ?? 0,
          sanitized['dismissed'] ?? 0,
          sanitized['created_at'] ?? DateTime.now().toIso8601String(),
        ]);
      }
      await batch.commit(noResult: true);
    });

    try {
      final docId = cards.first['document_id']?.toString();
      if (docId != null && docId.isNotEmpty) {
        await markCardsGenerated(docId, generated: true);
      }
    } catch (e) {
      debugPrint('Athena markCardsGenerated notice: $e');
    }
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

  Future<void> clearDocumentContent(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      try {
        await txn.rawDelete(
            'DELETE FROM reading_chunks_fts WHERE document_id = ?', [id]);
      } catch (e) {
        debugPrint('[Athena LocalDatabase] FTS clear notice: $e');
      }
      await txn.delete('reading_chunks',
          where: 'document_id = ?', whereArgs: [id]);
      await txn.delete('context_cards',
          where: 'document_id = ? AND saved = 0', whereArgs: [id]);
      await txn.delete('chunk_user_edits',
          where: 'document_id = ?', whereArgs: [id]);
      await txn.delete('document_pages',
          where: 'document_id = ?', whereArgs: [id]);
      await txn.update(
        'documents',
        {
          'status': 'processing',
          'stage': 'upload',
          'stage_label': 'Restarting ingestion...',
          'percent': 0,
          'chunk_count': 0,
          'cards_generated': 0,
          'canonical_text': null,
          'error_message': null,
          'error_code': null,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final safeId = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final tape = File(p.join(dir.path, '$safeId.athena.bin'));
        if (await tape.exists()) await tape.delete();
      } catch (e) {
        debugPrint('Athena BinaryBookTape clear notice: $e');
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
    final docMap = docRows.isNotEmpty
        ? Map<String, dynamic>.from(docRows.first)
        : <String, dynamic>{};

    // Check if BinaryBookTape exists BEFORE querying SQLite for heavy chunk text
    BinaryBookTape? openTape;
    if (!kIsWeb) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final safeId = documentId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
        final tapeFile = File(p.join(dir.path, '$safeId.athena.bin'));
        if (await tapeFile.exists()) {
          openTape = BinaryBookTape.fromBytes(await tapeFile.readAsBytes());
        }
      } catch (e) {
        debugPrint('Athena BinaryBookTape early check notice: $e');
      }
    }

    List<Map<String, Object?>> chunkRows;
    if (openTape != null) {
      // Query metadata columns ONLY - skip raw_text!
      chunkRows = await db.query(
        'reading_chunks',
        columns: [
          'id', 'document_id', 'sequence', 'section_title', 'section_role',
          'source_pages_json', 'start_offset', 'end_offset', 'checksum',
          'boundary_method', 'canonical_sha256'
        ],
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'sequence ASC',
      );
    } else {
      chunkRows = await db.query(
        'reading_chunks',
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'sequence ASC',
      );
    }

    var cardRows = await db.query('context_cards',
        where: 'document_id = ? AND dismissed = 0', whereArgs: [documentId]);

    final int cardsGenerated = (docMap['cards_generated'] as num?)?.toInt() ?? 0;

    // Safety fallback: If context_cards are empty for this document AND cards were never generated before, synthesize cards now!
    if (cardsGenerated == 0 && cardRows.isEmpty && chunkRows.isNotEmpty) {
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
      await markCardsGenerated(documentId, generated: true);
      docMap['cards_generated'] = 1;
    }

    final chunks = chunkRows.map((r) => Map<String, dynamic>.from(r)).toList();
    if (openTape != null && openTape.chunkCount == chunks.length) {
      for (var i = 0; i < chunks.length; i++) {
        chunks[i]['raw_text'] = openTape.getChunkText(i);
      }
    } else if (openTape != null && openTape.chunkCount != chunks.length) {
      // Mismatch fallback: reload with raw_text from SQLite
      final fullRows = await db.query(
        'reading_chunks',
        where: 'document_id = ?',
        whereArgs: [documentId],
        orderBy: 'sequence ASC',
      );
      chunks.clear();
      chunks.addAll(fullRows.map((r) => Map<String, dynamic>.from(r)));
    }

    final cards = cardRows.map((r) {
      final m = Map<String, dynamic>.from(r);
      m['type'] = 'context_card';
      return m;
    }).toList();

    // Group cards by chunk ID in O(M) time
    final cardsByChunkId = <String, List<Map<String, dynamic>>>{};
    for (final card in cards) {
      final srcId = card['source_chunk_id']?.toString() ?? '';
      if (srcId.isNotEmpty) {
        (cardsByChunkId[srcId] ??= []).add(card);
      }
    }

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
        'section_role': chunk['section_role'] ?? 'chapter',
        'boundary_method': chunk['boundary_method'] ?? 'paragraph',
      });

      final matchingCards = cardsByChunkId[chunk['id']] ?? const [];
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
          'support_status': card['support_status'] ?? 'unverified',
          'support_tier': card['support_tier'] ?? 'verified_external',
          'verified': card['verified'] == 1,
          'generation_mode': card['generation_mode'] ?? 'grounded',
          'is_speculative_draft':
              card['generation_mode'] == 'speculative_draft',
          'saved': card['saved'] == 1,
          'citations': citations,
        });
      }
    }

    if (!docMap.containsKey('integrity')) {
      docMap['integrity'] = {
        'verified': docMap['integrity_verified'] == 1,
        'chunk_count': chunks.length,
      };
    }

    // Preload chunk edits
    final editsRows = await db.query(
      'chunk_user_edits',
      where: 'document_id = ?',
      whereArgs: [documentId],
    );
    final chunkEditsMap = <String, Map<String, dynamic>>{
      for (final r in editsRows)
        (r['chunk_id'] as String): Map<String, dynamic>.from(r),
    };

    return {
      'document': docMap,
      'items': items,
      'chunks': chunks,
      'cards': cards,
      'chunk_edits': chunkEditsMap,
    };
  }

  Future<void> markCardsGenerated(String documentId, {bool generated = true}) async {
    final db = await database;
    await db.update(
      'documents',
      {'cards_generated': generated ? 1 : 0},
      where: 'id = ?',
      whereArgs: [documentId],
    );
  }

  Future<Map<String, dynamic>?> getChunkById(String chunkId) async {
    return getChunk(chunkId);
  }

  Future<void> updateReadingPosition(
    String documentId, {
    required int chunkIndex,
    String? chunkId,
    String readingMode = 'feed',
  }) async {
    final db = await database;
    final updates = <String, Object?>{
      'current_chunk_index': chunkIndex,
      'reading_mode': readingMode,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (chunkId != null) {
      updates['current_chunk_id'] = chunkId;
    }
    await db.update(
      'documents',
      updates,
      where: 'id = ?',
      whereArgs: [documentId],
    );
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
