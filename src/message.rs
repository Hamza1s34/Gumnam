//! Message protocol definitions and handling
//!
//! Port of Python message_protocol.py

use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

/// Types of messages in the protocol
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MessageType {
    Text,
    Handshake,
    Ack,
    KeyExchange,
    Ping,
    Pong,
    Image,
    Audio,
    File,
    Ipfs,
}

impl MessageType {
    pub fn as_str(&self) -> &'static str {
        match self {
            MessageType::Text => "text",
            MessageType::Handshake => "handshake",
            MessageType::Ack => "ack",
            MessageType::KeyExchange => "key_exchange",
            MessageType::Ping => "ping",
            MessageType::Pong => "pong",
            MessageType::Image => "image",
            MessageType::Audio => "audio",
            MessageType::File => "file",
            MessageType::Ipfs => "ipfs",
        }
    }
}

/// Represents a message in the protocol
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    #[serde(rename = "type")]
    pub msg_type: MessageType,
    pub payload: HashMap<String, serde_json::Value>,
    pub timestamp: i64,
    pub sender_id: Option<String>,
    pub recipient_id: Option<String>,
    pub signature: Option<String>, // Base64 signature
    pub version: String,
}

impl Message {
    /// Create a new message
    pub fn new(
        msg_type: MessageType,
        payload: HashMap<String, serde_json::Value>,
        sender_id: Option<String>,
        recipient_id: Option<String>,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            msg_type,
            payload,
            timestamp: Utc::now().timestamp(),
            sender_id,
            recipient_id,
            signature: None,
            version: "1.0".to_string(),
        }
    }

    /// Convert message to JSON string
    pub fn to_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(self)
    }

    /// Create message from JSON string
    pub fn from_json(json_str: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(json_str)
    }
}

/// Handles message protocol operations
pub struct MessageProtocol;

impl MessageProtocol {
    /// Create a text message
    pub fn create_text_message(text: &str, sender_id: &str, recipient_id: &str) -> Message {
        let mut payload = HashMap::new();
        payload.insert(
            "text".to_string(),
            serde_json::Value::String(text.to_string()),
        );

        Message::new(
            MessageType::Text,
            payload,
            Some(sender_id.to_string()),
            Some(recipient_id.to_string()),
        )
    }

    /// Create a handshake message with public key
    /// is_response: true if this is a response to a received handshake, false if initiating
    pub fn create_handshake_message(sender_id: &str, public_key: &str, is_response: bool) -> Message {
        let mut payload = HashMap::new();
        payload.insert(
            "public_key".to_string(),
            serde_json::Value::String(public_key.to_string()),
        );
        payload.insert(
            "protocol_version".to_string(),
            serde_json::Value::String("1.0".to_string()),
        );
        payload.insert(
            "is_response".to_string(),
            serde_json::Value::Bool(is_response),
        );

        Message::new(MessageType::Handshake, payload, Some(sender_id.to_string()), None)
    }

    /// Create an acknowledgment message
    pub fn create_ack_message(original_msg_id: &str, sender_id: &str) -> Message {
        let mut payload = HashMap::new();
        payload.insert(
            "original_msg_id".to_string(),
            serde_json::Value::String(original_msg_id.to_string()),
        );

        Message::new(MessageType::Ack, payload, Some(sender_id.to_string()), None)
    }

    /// Create a ping message
    pub fn create_ping_message(sender_id: &str) -> Message {
        Message::new(
            MessageType::Ping,
            HashMap::new(),
            Some(sender_id.to_string()),
            None,
        )
    }

    /// Create a pong message
    pub fn create_pong_message(sender_id: &str) -> Message {
        Message::new(
            MessageType::Pong,
            HashMap::new(),
            Some(sender_id.to_string()),
            None,
        )
    }

    /// Sign a message using the sender's private key
    pub fn sign_message(
        msg: &mut Message,
        crypto: &crate::crypto::CryptoHandler,
    ) -> anyhow::Result<()> {
        // We sign a string representation of the essential fields
        let data_to_sign = format!(
            "{}:{}:{:?}:{}:{:?}:{:?}",
            msg.id,
            msg.msg_type.as_str(),
            msg.payload,
            msg.timestamp,
            msg.sender_id,
            msg.recipient_id
        );

        let signature = crypto.sign_with_onion_key(&data_to_sign)
            .map_err(|e| anyhow::anyhow!("Signing failed: {}", e))?;
        
        msg.signature = Some(signature);
        Ok(())
    }

    /// Verify a message signature using the sender's onion address
    pub fn verify_message(
        msg: &Message,
        _unused_pk_pem: &str, // Signature is now checked against onion address directly
        crypto: &crate::crypto::CryptoHandler,
    ) -> bool {
        let signature = match &msg.signature {
            Some(s) => s,
            None => return false,
        };

        let sender_onion = match &msg.sender_id {
            Some(o) => o,
            None => return false,
        };

        let data_to_verify = format!(
            "{}:{}:{:?}:{}:{:?}:{:?}",
            msg.id,
            msg.msg_type.as_str(),
            msg.payload,
            msg.timestamp,
            msg.sender_id,
            msg.recipient_id
        );

        match crypto.verify_with_onion_address(&data_to_verify, signature, sender_onion) {
            Ok(valid) => valid,
            Err(_) => false,
        }
    }

    /// Validate message structure
    pub fn validate_message(msg: &Message) -> bool {
        // Check required fields
        if msg.id.is_empty() {
            return false;
        }

        // Check timestamp is reasonable (not too far in future - 5 minutes tolerance)
        let current_time = Utc::now().timestamp();
        if msg.timestamp > current_time + 300 {
            return false;
        }

        // Check version compatibility
        if msg.version != "1.0" {
            return false;
        }

        true
    }

    /// Wrap encrypted data in a message
    pub fn wrap_encrypted_message(
        encrypted_data: &crate::crypto::EncryptedData,
        sender_id: &str,
        recipient_id: &str,
    ) -> Message {
        let mut payload = HashMap::new();
        payload.insert(
            "encrypted".to_string(),
            serde_json::Value::Bool(true),
        );
        payload.insert(
            "data".to_string(),
            serde_json::to_value(encrypted_data).unwrap(),
        );

        Message::new(
            MessageType::Text,
            payload,
            Some(sender_id.to_string()),
            Some(recipient_id.to_string()),
        )
    }
}
