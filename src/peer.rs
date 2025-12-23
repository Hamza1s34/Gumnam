//! Peer management for tracking contacts and connections
//!
//! Port of Python peer_manager.py

use chrono::Utc;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::storage::{Contact, MessageStorage, StorageError};

/// Connection info for an active peer
#[derive(Debug, Clone)]
pub struct ConnectionInfo {
    pub connected_at: i64,
    pub info: HashMap<String, String>,
}

/// Manages peer connections and contact information
pub struct PeerManager {
    storage: Arc<Mutex<MessageStorage>>,
    active_connections: HashMap<String, ConnectionInfo>,
}

impl PeerManager {
    /// Create a new PeerManager
    pub fn new(storage: Arc<Mutex<MessageStorage>>) -> Self {
        Self {
            storage,
            active_connections: HashMap::new(),
        }
    }

    /// Add a new peer/contact
    pub fn add_peer(
        &self,
        onion_address: &str,
        nickname: Option<&str>,
        public_key: Option<&str>,
    ) -> Result<bool, StorageError> {
        let storage = self.storage.lock().unwrap();
        storage.add_contact(onion_address, nickname, public_key)
    }

    /// Get peer information
    pub fn get_peer(&self, onion_address: &str) -> Result<Option<Contact>, StorageError> {
        let storage = self.storage.lock().unwrap();
        storage.get_contact(onion_address)
    }

    /// Get all peers
    pub fn get_all_peers(&self) -> Result<Vec<Contact>, StorageError> {
        let storage = self.storage.lock().unwrap();
        storage.get_all_contacts()
    }

    /// Remove a peer
    pub fn remove_peer(&mut self, onion_address: &str) -> Result<bool, StorageError> {
        // Also disconnect if active
        self.disconnect_peer(onion_address);
        let storage = self.storage.lock().unwrap();
        storage.delete_contact(onion_address)
    }

    /// Update peer's public key
    pub fn update_peer_key(
        &self,
        onion_address: &str,
        public_key: &str,
    ) -> Result<bool, StorageError> {
        let storage = self.storage.lock().unwrap();
        if let Some(peer) = storage.get_contact(onion_address)? {
            storage.add_contact(onion_address, peer.nickname.as_deref(), Some(public_key))
        } else {
            Ok(false)
        }
    }

    /// Mark a peer as online/connected
    pub fn mark_peer_online(&mut self, onion_address: &str, connection_info: Option<HashMap<String, String>>) {
        self.active_connections.insert(
            onion_address.to_string(),
            ConnectionInfo {
                connected_at: Utc::now().timestamp(),
                info: connection_info.unwrap_or_default(),
            },
        );

        // Update last seen in storage
        if let Ok(storage) = self.storage.lock() {
            if let Ok(Some(peer)) = storage.get_contact(onion_address) {
                let _ = storage.add_contact(
                    onion_address,
                    peer.nickname.as_deref(),
                    peer.public_key.as_deref(),
                );
            }
        }
    }

    /// Mark a peer as disconnected
    pub fn disconnect_peer(&mut self, onion_address: &str) {
        self.active_connections.remove(onion_address);
    }

    /// Check if a peer is currently online
    pub fn is_peer_online(&self, onion_address: &str) -> bool {
        self.active_connections.contains_key(onion_address)
    }

    /// Get list of online peer addresses
    pub fn get_online_peers(&self) -> Vec<String> {
        self.active_connections.keys().cloned().collect()
    }

    // Public keys are now derived from onion addresses directly.
    // get_peer_public_key removed.
}
