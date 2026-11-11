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
             PRAGMA temp_store=MEMORY;",
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
                 (chunk_id, document_id, sequence, raw_text, page_number, page_start, page_end, start_char_offset, end_char_offset)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            )?;

            for chunk in chunks {
                let chunk_id = format!("{}_{}", doc_id, chunk.sequence);
                hasher.update(chunk.raw_text.as_bytes());

                insert_chunk.execute(params![
                    chunk_id,
                    doc_id,
                    chunk.sequence as i64,
                    chunk.raw_text,
                    chunk.page_start as i64,
                    chunk.page_start as i64,
                    chunk.page_end as i64,
                    chunk.start_offset as i64,
                    chunk.end_offset as i64,
                ])?;

                last_seq = chunk.sequence;
                last_char = chunk.end_offset;
            }
        }

        let new_chain_hash = hex::encode(hasher.finalize());

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
             heartbeat_at = datetime('now')
             WHERE id = ?8",
            params![
                window_page_end as i64,
                window_page_end as i64,
                last_seq as i64,
                last_char as i64,
                carry_over,
                new_chain_hash,
                status,
                doc_id,
            ],
        )?;

        tx.commit()?;
        Ok(new_chain_hash)
    }
}

