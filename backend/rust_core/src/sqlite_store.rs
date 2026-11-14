use crate::chunker::PlannedChunk;
use rusqlite::{params, Connection, Result};
use sha2::{Digest, Sha256};
use std::path::Path;

pub struct SqliteStore {
    conn: Connection,
}

impl SqliteStore {
    pub fn open<P: AsRef<Path>>(db_path: P) -> Result<Self> {
        let conn = Connection::open(db_path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA foreign_keys=ON;
             PRAGMA temp_store=MEMORY;
             PRAGMA busy_timeout=5000;
             CREATE TABLE IF NOT EXISTS reading_chunks (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                section_title TEXT,
                section_role TEXT DEFAULT 'chapter',
                raw_text TEXT NOT NULL,
                source_pages_json TEXT NOT NULL,
                page_start INTEGER DEFAULT 1,
                page_end INTEGER DEFAULT 1,
                page_number INTEGER DEFAULT 1,
                start_offset INTEGER NOT NULL,
                end_offset INTEGER NOT NULL,
                checksum TEXT NOT NULL,
                boundary_method TEXT NOT NULL,
                canonical_sha256 TEXT NOT NULL,
                simhash INTEGER,
                simhash_hi INTEGER,
                simhash_lo INTEGER,
                chain_hash TEXT,
                UNIQUE(document_id, sequence)
             );
             CREATE INDEX IF NOT EXISTS reading_chunks_document_sequence ON reading_chunks(document_id, sequence);
             CREATE INDEX IF NOT EXISTS idx_chunks_doc_page ON reading_chunks(document_id, page_start);

             CREATE VIRTUAL TABLE IF NOT EXISTS reading_chunks_fts USING fts5(
                chunk_id UNINDEXED, document_id UNINDEXED, raw_text, section_title,
                tokenize='porter unicode61 remove_diacritics 2'
             );

             CREATE TRIGGER IF NOT EXISTS reading_chunks_ai AFTER INSERT ON reading_chunks BEGIN
                INSERT INTO reading_chunks_fts(chunk_id, document_id, raw_text, section_title)
                VALUES (new.id, new.document_id, new.raw_text, new.section_title);
             END;

             CREATE TRIGGER IF NOT EXISTS reading_chunks_ad AFTER DELETE ON reading_chunks BEGIN
                DELETE FROM reading_chunks_fts WHERE chunk_id = old.id;
             END;

             CREATE TRIGGER IF NOT EXISTS reading_chunks_au AFTER UPDATE ON reading_chunks BEGIN
                DELETE FROM reading_chunks_fts WHERE chunk_id = old.id;
                INSERT INTO reading_chunks_fts(chunk_id, document_id, raw_text, section_title)
                VALUES (new.id, new.document_id, new.raw_text, new.section_title);
             END;",
        )?;
        Ok(Self { conn })
    }

    /// Commits an ingested window batch atomically into `reading_chunks` and updates document checkpoint columns.
    pub fn commit_window_batch(
        &mut self,
        doc_id: &str,
        window_page_start: usize,
        window_page_end: usize,
        chunks: &[PlannedChunk],
        carry_over: &str,
        prev_chain_hash: &str,
        status: &str,
    ) -> Result<String> {
        let tx = self.conn.transaction()?;

        let mut hasher = Sha256::new();
        hasher.update(prev_chain_hash.as_bytes());

        let mut last_seq = 0;
        let mut last_char = 0;

        {
            let mut insert_chunk = tx.prepare_cached(
                "INSERT OR REPLACE INTO reading_chunks 
                 (id, document_id, sequence, raw_text, start_offset, end_offset, page_start, page_end, page_number, section_title, section_role, source_pages_json, checksum, canonical_sha256, boundary_method, simhash, simhash_hi, simhash_lo, chain_hash)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)",
            )?;

            for chunk in chunks {
                let chunk_id = format!("{}-c{:06}", doc_id, chunk.sequence);
                hasher.update(chunk.raw_text.as_bytes());

                let mut chunk_hasher = Sha256::new();
                chunk_hasher.update(chunk.raw_text.as_bytes());
                let checksum = hex::encode(chunk_hasher.finalize());
                let simhash_u64 = crate::compute_simhash64(&chunk.raw_text);
                let simhash = simhash_u64 as i64;
                let simhash_hi = (simhash_u64 >> 32) as i64;
                let simhash_lo = (simhash_u64 & 0xFFFFFFFF) as i64;
                let pages_json = format!("[{}]", chunk.page_start);
                let intermediate_chain = hex::encode(hasher.clone().finalize());

                insert_chunk.execute(params![
                    chunk_id,
                    doc_id,
                    chunk.sequence as i64,
                    chunk.raw_text,
                    chunk.start_offset as i64,
                    chunk.end_offset as i64,
                    chunk.page_start as i64,
                    chunk.page_end as i64,
                    chunk.page_start as i64,
                    "Chapter Passage",
                    "chapter",
                    pages_json,
                    checksum,
                    checksum,
                    "paragraph",
                    simhash,
                    simhash_hi,
                    simhash_lo,
                    intermediate_chain,
                ])?;

                last_seq = chunk.sequence;
                last_char = chunk.end_offset;
            }
        }

        let new_chain_hash = hex::encode(hasher.finalize());
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;

        // Update documents checkpoint table
        tx.execute(
            "UPDATE documents SET 
             processed_page = ?1,
             last_checkpoint_page = ?2,
             last_chunk_sequence = ?3,
             last_char_offset = ?4,
             carry_over_text = ?5,
             chain_hash = ?6,
             status = ?7,
             heartbeat_at = ?8
             WHERE id = ?9",
            params![
                window_page_end as i64,
                window_page_end as i64,
                last_seq as i64,
                last_char as i64,
                carry_over,
                new_chain_hash,
                status,
                now_ms,
                doc_id,
            ],
        )?;

        tx.commit()?;
        Ok(new_chain_hash)
    }
}

