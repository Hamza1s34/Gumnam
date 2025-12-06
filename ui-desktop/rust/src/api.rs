use flutter_rust_bridge::frb;
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;
use once_cell::sync::Lazy;
use tor_messenger::tor_service::TorService;
use tor_messenger::storage::MessageStorage;
use tor_messenger::crypto::CryptoHandler;
use tor_messenger::peer::PeerManager;
use tor_messenger::message::{Message as ProtocolMessage, MessageType, MessageProtocol};

// Global state
static TOR_SERVICE: Lazy<Arc<Mutex<Option<TorService>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));
static STORAGE: Lazy<Arc<Mutex<Option<MessageStorage>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));
static CRYPTO: Lazy<Arc<Mutex<Option<CryptoHandler>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));
static PEER_MANAGER: Lazy<Arc<Mutex<Option<PeerManager>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));

// Web messages queue for real-time updates
static WEB_MESSAGES: Lazy<Arc<Mutex<VecDeque<WebMessageInfo>>>> = Lazy::new(|| Arc::new(Mutex::new(VecDeque::new())));

// Counter for new incoming messages (to trigger UI refresh)
static NEW_MESSAGE_COUNT: Lazy<Arc<Mutex<i32>>> = Lazy::new(|| Arc::new(Mutex::new(0)));

// Special contact identifier for web messages
pub const WEB_CONTACT_ADDRESS: &str = "web_messages_contact";
pub const WEB_CONTACT_NAME: &str = "🌐 Web Messages";

#[derive(Debug, Clone)]
pub struct ContactInfo {
    pub onion_address: String,
    pub nickname: String,
    pub last_seen: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct MessageInfo {
    pub id: String,
    pub text: String,
    pub sender_id: String,
    pub recipient_id: String,
    pub timestamp: i64,
    pub is_sent: bool,
    pub is_read: bool,
}

#[derive(Debug, Clone)]
pub struct WebMessageInfo {
    pub id: String,
    pub sender: String,
    pub text: String,
    pub timestamp: i64,
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub fn start_tor() -> anyhow::Result<String> {
    // Initialize storage first
    let mut storage_guard = STORAGE.lock().unwrap();
    if storage_guard.is_none() {
        let storage = MessageStorage::new().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        storage.init_database().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        *storage_guard = Some(storage);
    }
    drop(storage_guard);
    
    // Initialize crypto
    let mut crypto_guard = CRYPTO.lock().unwrap();
    if crypto_guard.is_none() {
        let crypto = CryptoHandler::new().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        *crypto_guard = Some(crypto);
    }
    drop(crypto_guard);
    
    // Initialize peer manager
    let mut pm_guard = PEER_MANAGER.lock().unwrap();
    if pm_guard.is_none() {
        let storage_arc = Arc::new(Mutex::new(
            MessageStorage::new().map_err(|e| anyhow::anyhow!(e.to_string()))?
        ));
        let pm = PeerManager::new(storage_arc);
        *pm_guard = Some(pm);
    }
    drop(pm_guard);
    
    let mut service_guard = TOR_SERVICE.lock().unwrap();
    if service_guard.is_none() {
        // Create message handler that handles ALL incoming messages
        let handler: Box<dyn Fn(String) + Send + Sync> = Box::new(|msg_str: String| {
            handle_incoming_message(&msg_str);
        });
        
        let service = TorService::new(Some(handler)); 
        service.start().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        *service_guard = Some(service);
    }
    
    let service = service_guard.as_ref().unwrap();
    let onion = service.get_onion_address().unwrap_or_default();
    
    Ok(onion)
}

pub fn get_onion_address() -> String {
    let service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.as_ref() {
        service.get_onion_address().unwrap_or_default()
    } else {
        "".to_string()
    }
}

pub fn stop_tor() {
    let mut service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.take() {
        service.stop();
    }
}

/// Handle incoming messages - STRICT PROTOCOL ONLY
/// Only accepts properly formatted encrypted protocol messages
fn handle_incoming_message(msg_str: &str) {
    // STRICT: Must be valid JSON
    let msg_data = match serde_json::from_str::<serde_json::Value>(msg_str) {
        Ok(data) => data,
        Err(_) => {
            // Silently ignore non-JSON messages (like PING/OK)
            let trimmed = msg_str.trim();
            if trimmed != "PING" && trimmed != "OK" && !trimmed.is_empty() {
                println!("⚠ [Flutter] Rejected non-protocol message (not JSON)");
            }
            return;
        }
    };
    
    // Check if it's a web message (special case for web interface)
    if msg_data.get("type").and_then(|v| v.as_str()) == Some("web_message") {
        handle_web_message(&msg_data);
        return;
    }
    
    // STRICT: Must be a valid protocol message
    let msg = match ProtocolMessage::from_json(msg_str) {
        Ok(m) => m,
        Err(_) => {
            println!("⚠ [Flutter] Rejected invalid protocol message format");
            return;
        }
    };
    
    // STRICT: Must have sender_id
    if msg.sender_id.is_none() {
        println!("⚠ [Flutter] Rejected message without sender_id");
        return;
    }
    
    match msg.msg_type {
        MessageType::Handshake => {
            handle_handshake_message(&msg);
        }
        MessageType::Text => {
            // STRICT: Text messages MUST be encrypted
            if msg.payload.get("encrypted").and_then(|v| v.as_bool()) != Some(true) {
                println!("⚠ [Flutter] Rejected unencrypted text message from {:?}", msg.sender_id);
                return;
            }
            handle_text_message(&msg);
        }
        _ => {
            // Ignore other message types
        }
    }
}

/// Handle web messages from browser
fn handle_web_message(msg_data: &serde_json::Value) {
    let sender = msg_data.get("sender").and_then(|v| v.as_str()).unwrap_or("Anonymous");
    let text = msg_data.get("text").and_then(|v| v.as_str()).unwrap_or("");
    
    let timestamp = chrono::Utc::now().timestamp();
    let msg_id = uuid::Uuid::new_v4().to_string();
    
    // Add to web messages queue
    let web_msg = WebMessageInfo {
        id: msg_id.clone(),
        sender: sender.to_string(),
        text: text.to_string(),
        timestamp,
    };
    
    if let Ok(mut queue) = WEB_MESSAGES.lock() {
        queue.push_back(web_msg);
        while queue.len() > 100 {
            queue.pop_front();
        }
    }
    
    // Save to storage
    if let Ok(storage_guard) = STORAGE.lock() {
        if let Some(storage) = storage_guard.as_ref() {
            let payload = serde_json::json!({
                "text": text,
                "web_sender": sender
            });
            let _ = storage.save_message(
                &msg_id,
                "web_message",
                Some(WEB_CONTACT_ADDRESS),
                None,
                &payload,
                timestamp,
                false,
            );
        }
    }
    
    // Increment new message counter
    if let Ok(mut count) = NEW_MESSAGE_COUNT.lock() {
        *count += 1;
    }
    
    println!("📨 [Flutter] Web message from '{}': {}", sender, text);
}

/// Handle handshake messages - exchange keys with peers
fn handle_handshake_message(msg: &ProtocolMessage) {
    // sender_id is guaranteed to exist (checked in handle_incoming_message)
    let sender_id = msg.sender_id.as_ref().unwrap();
    
    // STRICT: Must have public_key in payload
    let public_key = match msg.payload.get("public_key").and_then(|v| v.as_str()) {
        Some(pk) => pk,
        None => {
            println!("⚠ [Flutter] Rejected handshake without public_key from {}", sender_id);
            return;
        }
    };
    
    let is_response = msg.payload.get("is_response")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    
    // Save the sender's public key
    if let Ok(mut pm) = PEER_MANAGER.lock() {
        if let Some(ref mut peer_manager) = *pm {
            let _ = peer_manager.add_peer(sender_id, None, Some(public_key));
            peer_manager.mark_peer_online(sender_id, None);
        }
    }
    
    if is_response {
        println!("✓ [Flutter] Response handshake from: {} (key exchange complete)", sender_id);
    } else {
        println!("✓ [Flutter] Handshake from: {} (sending response)", sender_id);
        
        // Send response handshake with our public key
        if let Ok(crypto_guard) = CRYPTO.lock() {
            if let Some(ref crypto) = *crypto_guard {
                if let Ok(our_pk) = crypto.get_public_key_pem() {
                    let our_onion = get_onion_address();
                    let response_handshake = MessageProtocol::create_handshake_message(&our_onion, &our_pk, true);
                    
                    if let Ok(json) = response_handshake.to_json() {
                        let peer = sender_id.clone();
                        let json_clone = json.clone();
                        std::thread::spawn(move || {
                            let service_guard = TOR_SERVICE.lock().unwrap();
                            if let Some(ref service) = *service_guard {
                                match service.send_message(&peer, &json_clone) {
                                    Ok(_) => println!("✓ [Flutter] Response handshake sent to {}", peer),
                                    Err(e) => println!("✗ [Flutter] Response handshake failed: {}", e),
                                }
                            }
                        });
                    }
                }
            }
        }
    }
}

/// Handle encrypted text messages - STRICT: Only encrypted messages accepted
fn handle_text_message(msg: &ProtocolMessage) {
    // sender_id is guaranteed to exist (checked in handle_incoming_message)
    let sender = msg.sender_id.as_ref().unwrap();
    
    // STRICT: encrypted flag already verified in handle_incoming_message
    // STRICT: Must have data field
    let data = match msg.payload.get("data") {
        Some(d) => d,
        None => {
            println!("⚠ [Flutter] Rejected encrypted message without data from {}", sender);
            return;
        }
    };
    
    // STRICT: Must be valid EncryptedData structure
    let encrypted_data = match serde_json::from_value::<tor_messenger::crypto::EncryptedData>(data.clone()) {
        Ok(ed) => ed,
        Err(_) => {
            println!("⚠ [Flutter] Rejected invalid encrypted data format from {}", sender);
            return;
        }
    };
    
    // Decrypt the message
    if let Ok(crypto_guard) = CRYPTO.lock() {
        if let Some(ref crypto) = *crypto_guard {
            match crypto.decrypt_message(&encrypted_data) {
                Ok(decrypted_text) => {
                    println!("← [Flutter] From {}: {}", sender, decrypted_text);
                    
                    // Save to storage
                    if let Ok(storage_guard) = STORAGE.lock() {
                        if let Some(storage) = storage_guard.as_ref() {
                            let payload = serde_json::json!({"text": &decrypted_text});
                            let _ = storage.save_message(
                                &msg.id,
                                "text",
                                msg.sender_id.as_deref(),
                                msg.recipient_id.as_deref(),
                                &payload,
                                msg.timestamp,
                                false,
                            );
                        }
                    }
                    
                    // Increment new message counter
                    if let Ok(mut count) = NEW_MESSAGE_COUNT.lock() {
                        *count += 1;
                    }
                }
                Err(e) => {
                    println!("✗ [Flutter] Decryption error from {}: {}", sender, e);
                }
            }
        }
    }
}

/// Get count of new messages since last check (for polling)
pub fn get_new_message_count() -> i32 {
    if let Ok(mut count) = NEW_MESSAGE_COUNT.lock() {
        let current = *count;
        *count = 0;  // Reset after reading
        current
    } else {
        0
    }
}

pub fn send_message(onion_address: String, message: String) -> anyhow::Result<bool> {
    println!("[DEBUG] send_message called: to={}, msg={}", onion_address, message);
    
    let service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.as_ref() {
        let my_address = service.get_onion_address().unwrap_or_default();
        println!("[DEBUG] My address: {}", my_address);
        
        // STRICT VALIDATION: Get recipient's public key - REQUIRED for encryption
        let pm_guard = PEER_MANAGER.lock().unwrap();
        let public_key = pm_guard.as_ref().and_then(|pm| pm.get_peer_public_key(&onion_address));
        drop(pm_guard);
        
        println!("[DEBUG] Public key for recipient: {:?}", public_key.is_some());
        
        // STRICT: Public key is REQUIRED - no unencrypted messages allowed
        let pk = public_key.ok_or_else(|| {
            println!("[DEBUG] ERROR: No public key for recipient!");
            anyhow::anyhow!("Cannot send message: No public key for recipient. Please exchange handshake first.")
        })?;
        
        // STRICT: Crypto handler is REQUIRED
        let crypto_guard = CRYPTO.lock().unwrap();
        let crypto = crypto_guard.as_ref().ok_or_else(|| {
            println!("[DEBUG] ERROR: Crypto not initialized!");
            anyhow::anyhow!("Cannot send message: Crypto not initialized.")
        })?;
        
        // STRICT: Encrypt the message - REQUIRED, no fallback to plaintext
        let encrypted_data = crypto.encrypt_message(&message, &pk)
            .map_err(|e| {
                println!("[DEBUG] ERROR: Encryption failed: {}", e);
                anyhow::anyhow!("Encryption failed: {}. Message NOT sent.", e)
            })?;
        
        println!("[DEBUG] Message encrypted successfully");
        
        // Create encrypted protocol message with sender_id
        let msg = MessageProtocol::wrap_encrypted_message(
            &encrypted_data,
            &my_address,
            &onion_address,
        );
        let msg_id = msg.id.clone();
        let timestamp = msg.timestamp;
        let msg_json = msg.to_json().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        
        println!("[DEBUG] Protocol message JSON length: {}", msg_json.len());
        println!("[DEBUG] Protocol message (first 200 chars): {}", &msg_json[..std::cmp::min(200, msg_json.len())]);
        
        drop(crypto_guard);
        
        // Save sent message to storage
        let storage_guard = STORAGE.lock().unwrap();
        if let Some(storage) = storage_guard.as_ref() {
            let payload = serde_json::json!({"text": message});
            let _ = storage.save_message(
                &msg_id,
                "text",
                Some(&my_address),
                Some(&onion_address),
                &payload,
                timestamp,
                true,
            );
        }
        drop(storage_guard);
        
        // Send the encrypted protocol message
        println!("[DEBUG] Sending message via Tor...");
        let result = service.send_message(&onion_address, &msg_json);
        println!("[DEBUG] Send result: {:?}", result.is_ok());
        result.map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
        println!("[DEBUG] ERROR: Tor service not started!");
        Err(anyhow::anyhow!("Tor service not started"))
    }
}

// Contact management APIs
pub fn get_contacts() -> anyhow::Result<Vec<ContactInfo>> {
    let storage_guard = STORAGE.lock().unwrap();
    let mut contacts = Vec::new();
    
    // Always add the Web Messages contact first
    contacts.push(ContactInfo {
        onion_address: WEB_CONTACT_ADDRESS.to_string(),
        nickname: WEB_CONTACT_NAME.to_string(),
        last_seen: Some(chrono::Utc::now().timestamp()),
    });
    
    if let Some(storage) = storage_guard.as_ref() {
        let db_contacts = storage.get_all_contacts().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        for c in db_contacts {
            contacts.push(ContactInfo {
                onion_address: c.onion_address,
                nickname: c.nickname.unwrap_or_else(|| "Unknown".to_string()),
                last_seen: c.last_seen,
            });
        }
    }
    Ok(contacts)
}

pub fn add_contact(onion_address: String, nickname: String) -> anyhow::Result<bool> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        storage.add_contact(&onion_address, Some(&nickname), None)
            .map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}

pub fn delete_contact(onion_address: String) -> anyhow::Result<bool> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        storage.delete_contact(&onion_address)
            .map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}

// Message APIs
pub fn get_messages(contact_onion: Option<String>, limit: i32) -> anyhow::Result<Vec<MessageInfo>> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        // Handle web messages specially
        if contact_onion.as_deref() == Some(WEB_CONTACT_ADDRESS) {
            return get_web_messages_from_storage(storage, limit as usize);
        }
        
        let messages = storage.get_messages(contact_onion.as_deref(), limit as usize)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(messages.into_iter().map(|m| MessageInfo {
            id: m.id,
            text: m.payload.get("text").and_then(|t| t.as_str()).unwrap_or("").to_string(),
            sender_id: m.sender_id.unwrap_or_default(),
            recipient_id: m.recipient_id.unwrap_or_default(),
            timestamp: m.timestamp,
            is_sent: m.is_sent,
            is_read: m.is_read,
        }).collect())
    } else {
        Ok(vec![])
    }
}

// Get web messages from storage
fn get_web_messages_from_storage(storage: &MessageStorage, limit: usize) -> anyhow::Result<Vec<MessageInfo>> {
    let messages = storage.get_messages(Some(WEB_CONTACT_ADDRESS), limit)
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    
    Ok(messages.into_iter().map(|m| {
        // For web messages, the sender name is stored in the payload
        let web_sender = m.payload.get("web_sender")
            .and_then(|s| s.as_str())
            .unwrap_or("Anonymous");
        let text = m.payload.get("text")
            .and_then(|t| t.as_str())
            .unwrap_or("");
        
        MessageInfo {
            id: m.id,
            text: format!("[{}]: {}", web_sender, text),
            sender_id: WEB_CONTACT_ADDRESS.to_string(),
            recipient_id: "me".to_string(),
            timestamp: m.timestamp,
            is_sent: false,
            is_read: m.is_read,
        }
    }).collect())
}

// Get pending web messages (for polling)
pub fn get_pending_web_messages() -> Vec<WebMessageInfo> {
    if let Ok(mut queue) = WEB_MESSAGES.lock() {
        queue.drain(..).collect()
    } else {
        vec![]
    }
}

// Get count of unread web messages
pub fn get_web_message_count() -> i32 {
    if let Ok(queue) = WEB_MESSAGES.lock() {
        queue.len() as i32
    } else {
        0
    }
}

// Delete a chat (contact + all messages)
pub fn delete_chat(onion_address: String) -> anyhow::Result<bool> {
    // Don't allow deleting the web messages contact
    if onion_address == WEB_CONTACT_ADDRESS {
        return Err(anyhow::anyhow!("Cannot delete web messages contact"));
    }
    
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        storage.delete_chat(&onion_address)
            .map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}

// Clear all messages for a chat (keep contact)
pub fn clear_chat(onion_address: String) -> anyhow::Result<i32> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        let count = storage.clear_chat(&onion_address)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(count as i32)
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}
