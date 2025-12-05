//! Message storage using SQLite
//!
//! Port of Python message_storage.py

use chrono::Utc;
use rusqlite::{params, Connection, Result as SqliteResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use thiserror::Error;

use crate::config;

#[derive(Error, Debug)]
pub enum StorageError {
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}

/// Stored message structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub id: String,
    pub msg_type: String,
    pub sender_id: Option<String>,
    pub recipient_id: Option<String>,
    pub payload: serde_json::Value,
    pub timestamp: i64,
    pub is_sent: bool,
    pub is_read: bool,
}

/// Contact structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Contact {
    pub onion_address: String,
    pub nickname: Option<String>,
    pub public_key: Option<String>,
    pub last_seen: Option<i64>,
}

/// Handles persistent storage of messages and contacts
pub struct MessageStorage {
    db_path: PathBuf,
}

impl MessageStorage {
    /// Create a new MessageStorage with default database path
    pub fn new() -> Result<Self, StorageError> {
        Self::with_path(config::db_path())
    }

    /// Create a new MessageStorage with custom database path
    pub fn with_path(db_path: PathBuf) -> Result<Self, StorageError> {
        let storage = Self { db_path };
        storage.init_database()?;
        Ok(storage)
    }

    /// Get a database connection
    fn connection(&self) -> SqliteResult<Connection> {
        Connection::open(&self.db_path)
    }

    /// Initialize database schema
    pub fn init_database(&self) -> Result<(), StorageError> {
        let conn = self.connection()?;

        // Messages table
        conn.execute(
            "CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                sender_id TEXT,
                recipient_id TEXT,
                payload TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                is_sent BOOLEAN NOT NULL,
                is_read BOOLEAN DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )?;

        // Contacts table
        conn.execute(
            "CREATE TABLE IF NOT EXISTS contacts (
                onion_address TEXT PRIMARY KEY,
                nickname TEXT,
                public_key TEXT,
                last_seen INTEGER,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )",
            [],
        )?;

        // Create indexes
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_timestamp 
             ON messages(timestamp DESC)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_sender 
             ON messages(sender_id)",
            [],
        )?;

        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_messages_recipient 
             ON messages(recipient_id)",
            [],
        )?;

        Ok(())
    }

    /// Save a message to the database
    pub fn save_message(
        &self,
        msg_id: &str,
        msg_type: &str,
        sender_id: Option<&str>,
        recipient_id: Option<&str>,
        payload: &serde_json::Value,
        timestamp: i64,
        is_sent: bool,
    ) -> Result<bool, StorageError> {
        let conn = self.connection()?;
        let payload_str = serde_json::to_string(payload)?;

        match conn.execute(
            "INSERT INTO messages 
             (id, type, sender_id, recipient_id, payload, timestamp, is_sent)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![msg_id, msg_type, sender_id, recipient_id, payload_str, timestamp, is_sent],
        ) {
            Ok(_) => Ok(true),
            Err(rusqlite::Error::SqliteFailure(err, _))
                if err.code == rusqlite::ffi::ErrorCode::ConstraintViolation =>
            {
                // Message already exists
                Ok(false)
            }
            Err(e) => Err(StorageError::Database(e)),
        }
    }

    /// Get messages, optionally filtered by contact
    pub fn get_messages(
        &self,
        contact_onion: Option<&str>,
        limit: usize,
    ) -> Result<Vec<StoredMessage>, StorageError> {
        let conn = self.connection()?;
        let mut messages = Vec::new();

        if let Some(contact) = contact_onion {
            let mut stmt = conn.prepare(
                "SELECT id, type, sender_id, recipient_id, payload, 
                        timestamp, is_sent, is_read
                 FROM messages
                 WHERE sender_id = ?1 OR recipient_id = ?1
                 ORDER BY timestamp DESC
                 LIMIT ?2",
            )?;

            let rows = stmt.query_map(params![contact, limit as i64], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    msg_type: row.get(1)?,
                    sender_id: row.get(2)?,
                    recipient_id: row.get(3)?,
                    payload: serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or_default(),
                    timestamp: row.get(5)?,
                    is_sent: row.get(6)?,
                    is_read: row.get(7)?,
                })
            })?;

            for row in rows {
                messages.push(row?);
            }
        } else {
            let mut stmt = conn.prepare(
                "SELECT id, type, sender_id, recipient_id, payload, 
                        timestamp, is_sent, is_read
                 FROM messages
                 ORDER BY timestamp DESC
                 LIMIT ?1",
            )?;

            let rows = stmt.query_map(params![limit as i64], |row| {
                Ok(StoredMessage {
                    id: row.get(0)?,
                    msg_type: row.get(1)?,
                    sender_id: row.get(2)?,
                    recipient_id: row.get(3)?,
                    payload: serde_json::from_str(&row.get::<_, String>(4)?).unwrap_or_default(),
                    timestamp: row.get(5)?,
                    is_sent: row.get(6)?,
                    is_read: row.get(7)?,
                })
            })?;

            for row in rows {
                messages.push(row?);
            }
        }

        Ok(messages)
    }

    /// Mark a message as read
    pub fn mark_as_read(&self, msg_id: &str) -> Result<bool, StorageError> {
        let conn = self.connection()?;
        let updated = conn.execute(
            "UPDATE messages SET is_read = 1 WHERE id = ?1",
            params![msg_id],
        )?;
        Ok(updated > 0)
    }

    /// Add or update a contact
    pub fn add_contact(
        &self,
        onion_address: &str,
        nickname: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, StorageError> {
        let conn = self.connection()?;
        let last_seen = Utc::now().timestamp();

        conn.execute(
            "INSERT OR REPLACE INTO contacts 
             (onion_address, nickname, public_key, last_seen)
             VALUES (?1, ?2, ?3, ?4)",
            params![onion_address, nickname, public_key, last_seen],
        )?;

        Ok(true)
    }

    /// Get contact information
    pub fn get_contact(&self, onion_address: &str) -> Result<Option<Contact>, StorageError> {
        let conn = self.connection()?;

        let mut stmt = conn.prepare(
            "SELECT onion_address, nickname, public_key, last_seen
             FROM contacts
             WHERE onion_address = ?1",
        )?;

        let contact = stmt
            .query_row(params![onion_address], |row| {
                Ok(Contact {
                    onion_address: row.get(0)?,
                    nickname: row.get(1)?,
                    public_key: row.get(2)?,
                    last_seen: row.get(3)?,
                })
            })
            .ok();

        Ok(contact)
    }

    /// Get all contacts
    pub fn get_all_contacts(&self) -> Result<Vec<Contact>, StorageError> {
        let conn = self.connection()?;
        let mut contacts = Vec::new();

        let mut stmt = conn.prepare(
            "SELECT onion_address, nickname, public_key, last_seen
             FROM contacts
             ORDER BY last_seen DESC",
        )?;

        let rows = stmt.query_map([], |row| {
            Ok(Contact {
                onion_address: row.get(0)?,
                nickname: row.get(1)?,
                public_key: row.get(2)?,
                last_seen: row.get(3)?,
            })
        })?;

        for row in rows {
            contacts.push(row?);
        }

        Ok(contacts)
    }

    /// Delete a contact
    pub fn delete_contact(&self, onion_address: &str) -> Result<bool, StorageError> {
        let conn = self.connection()?;
        let deleted = conn.execute(
            "DELETE FROM contacts WHERE onion_address = ?1",
            params![onion_address],
        )?;
        Ok(deleted > 0)
    }

    /// Delete all messages for a contact
    pub fn delete_messages_for_contact(&self, onion_address: &str) -> Result<usize, StorageError> {
        let conn = self.connection()?;
        let deleted = conn.execute(
            "DELETE FROM messages WHERE sender_id = ?1 OR recipient_id = ?1",
            params![onion_address],
        )?;
        Ok(deleted)
    }

    /// Clear all messages for a contact (alias for delete_messages_for_contact)
    pub fn clear_chat(&self, onion_address: &str) -> Result<usize, StorageError> {
        self.delete_messages_for_contact(onion_address)
    }

    /// Delete a contact and all their messages
    pub fn delete_chat(&self, onion_address: &str) -> Result<bool, StorageError> {
        self.delete_messages_for_contact(onion_address)?;
        self.delete_contact(onion_address)
    }
}

impl Default for MessageStorage {
    fn default() -> Self {
        Self::new().expect("Failed to initialize MessageStorage")
    }
}
