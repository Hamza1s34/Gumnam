use flutter_rust_bridge::frb;
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;
use once_cell::sync::Lazy;
use base64::prelude::*;
use std::fs;
use std::path::Path;
use gumnam::tor_service::TorService;
use gumnam::storage::MessageStorage;
use gumnam::crypto::CryptoHandler;
use gumnam::peer::PeerManager;
use gumnam::message::{Message as ProtocolMessage, MessageType, MessageProtocol};

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
    pub public_key: Option<String>,
}

/// Detailed contact information for the contact info dialog
#[derive(Debug, Clone)]
pub struct ContactDetails {
    pub onion_address: String,
    pub nickname: String,
    pub public_key: Option<String>,
    pub last_seen: Option<i64>,
    pub first_message_time: Option<i64>,
    pub last_message_time: Option<i64>,
    pub total_messages: i32,
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
    pub msg_type: Option<String>,
}

#[derive(Debug, Clone)]

pub struct WebMessageInfo {
    pub id: String,
    pub sender: String,
    pub text: String,
    pub timestamp: i64,
    pub msg_type: String, // Web messages are usually text but good to align
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
    
    // Fix any existing contacts with bad nicknames
    println!("[*] Checking and fixing contact nicknames...");
    let _ = fix_contact_nicknames();
    
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
    
    // Load the Ed25519 identity key from Tor for signing and ECIES decryption
    println!("[*] Loading onion identity key for signatures and decryption...");
    match service.get_onion_secret_key() {
        Ok(key_bytes) => {
            if let Ok(mut c) = CRYPTO.lock() {
                if let Some(ref mut crypto) = *c {
                    if let Err(e) = crypto.set_onion_signing_key(&key_bytes) {
                        println!("[!] Warning: Failed to load onion identity key: {}", e);
                    } else {
                        println!("[✓] Identity linked to onion address! Signatures and ECIES ready.");
                    }
                }
            }
        }
        Err(e) => println!("[!] Warning: Could not load onion identity key: {}", e),
    }
    
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

/// Get my own onion address (ECIES - public key derived from onion address)
pub fn get_my_public_key() -> anyhow::Result<String> {
    // ECIES: We don't need a separate public key, just return the onion address
    let onion = get_onion_address();
    if onion.is_empty() {
        Err(anyhow::anyhow!("Tor not started"))
    } else {
        Ok(onion)
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
        Err(e) => {
            println!("⚠ [Flutter] Rejected invalid protocol message format: {}", e);
            println!("[DEBUG] Raw message (first 500 chars): {:.500}", msg_str);
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
        MessageType::Encrypted => {
            // ECIES encrypted messages - decrypt directly
            handle_encrypted_message(&msg);
        }
        MessageType::Text => {
            // STRICT: Text messages MUST be encrypted (legacy format)
            if msg.payload.get("encrypted").and_then(|v| v.as_bool()) != Some(true) {
                println!("⚠ [Flutter] Rejected unencrypted text message from {:?}", msg.sender_id);
                return;
            }
            handle_text_message(&msg);
        }
        MessageType::Image | MessageType::Audio | MessageType::File => {
             // STRICT: Media messages MUST be encrypted
            if msg.payload.get("encrypted").and_then(|v| v.as_bool()) != Some(true) {
                println!("⚠ [Flutter] Rejected unencrypted media message from {:?}", msg.sender_id);
                return;
            }
            handle_file_message(&msg);
        }
        _ => {
            // Ignore other message types
            println!("ℹ [Flutter] Ignoring message type: {:?}", msg.msg_type);
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
        msg_type: "text".to_string(),
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

/// Handle handshake messages - ECIES doesn't require public key exchange,
/// but we still accept handshakes to add contacts and maintain compatibility
fn handle_handshake_message(msg: &ProtocolMessage) {
    let sender_id = msg.sender_id.as_ref().unwrap();
    
    let is_response = msg.payload.get("is_response")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    
    // ECIES: We don't need public keys, just add the contact
    if let Ok(storage_guard) = STORAGE.lock() {
        if let Some(storage) = storage_guard.as_ref() {
            // Check if contact already exists
            let contact_exists = storage.get_contact(sender_id).ok().flatten().is_some();
            if !contact_exists {
                // Sanitize nickname to only use ASCII characters to avoid UTF-16 issues
                let safe_prefix = sender_id.chars()
                    .filter(|c| c.is_ascii_alphanumeric())
                    .take(12)
                    .collect::<String>();
                let default_nickname = if safe_prefix.is_empty() {
                    "Contact".to_string()
                } else {
                    safe_prefix
                };
                let _ = storage.add_contact(sender_id, Some(&default_nickname), None);
                println!("✓ [Flutter] Added new contact from handshake: {}", default_nickname);
            }
        }
    }
    
    // Update peer manager (for online status)
    if let Ok(mut pm) = PEER_MANAGER.lock() {
        if let Some(ref mut peer_manager) = *pm {
            peer_manager.mark_peer_online(sender_id, None);
        }
    }
    
    if is_response {
        println!("✓ [Flutter ECIES] Handshake response from: {}", sender_id);
    } else {
        println!("✓ [Flutter ECIES] Handshake from: {} (sending response)", sender_id);
        
        // Send a simple response handshake IMMEDIATELY (no public key needed for ECIES)
        // This is CRITICAL - we must respond quickly to avoid blocking the sender
        let our_onion = get_onion_address();
        let response_handshake = MessageProtocol::create_handshake_message(&our_onion, true);
        
        if let Ok(json) = response_handshake.to_json() {
            let peer = sender_id.clone();
            let json_clone = json.clone();
            // Spawn immediately to avoid blocking
            std::thread::spawn(move || {
                let service_guard = TOR_SERVICE.lock().unwrap();
                if let Some(ref service) = *service_guard {
                    match service.send_message(&peer, &json_clone) {
                        Ok(_) => println!("✓ [Flutter] Response handshake sent to {}", peer),
                        Err(e) => println!("✗ [Flutter] Response handshake failed: {}", e),
                    }
                } else {
                    println!("✗ [Flutter] Tor service not available for handshake response");
                }
            });
        }
    }
}

/// Handle ECIES encrypted messages (new format from CLI)
fn handle_encrypted_message(msg: &ProtocolMessage) {
    let sender = msg.sender_id.as_ref().unwrap().clone();
    
    // Extract encrypted data from payload
    let encrypted_data = match msg.payload.get("data") {
        Some(data) => {
            match serde_json::from_value::<gumnam::crypto::EncryptedData>(data.clone()) {
                Ok(ed) => ed,
                Err(e) => {
                    println!("⚠ [Flutter] Invalid encrypted data format from {}: {}", sender, e);
                    return;
                }
            }
        }
        None => {
            println!("⚠ [Flutter] Encrypted message missing 'data' field from {}", sender);
            return;
        }
    };
    
    // Check if sender is a known contact, if not create one
    let is_new_contact = {
        let storage_guard = STORAGE.lock().ok();
        let contact_exists = storage_guard.as_ref()
            .and_then(|s| s.as_ref())
            .and_then(|s| s.get_contact(&sender).ok())
            .flatten()
            .is_some();
        
        if !contact_exists {
            println!("📱 [Flutter] New contact detected: {}", sender);
            if let Ok(storage_guard) = STORAGE.lock() {
                if let Some(storage) = storage_guard.as_ref() {
                    // Sanitize nickname to only use ASCII characters to avoid UTF-16 issues
                    let safe_prefix = sender.chars()
                        .filter(|c| c.is_ascii_alphanumeric())
                        .take(12)
                        .collect::<String>();
                    let default_nickname = if safe_prefix.is_empty() {
                        "Contact".to_string()
                    } else {
                        safe_prefix
                    };
                    let _ = storage.add_contact(&sender, Some(&default_nickname), None);
                    println!("✓ [Flutter] Created new contact: {}", default_nickname);
                }
            }
            true
        } else {
            false
        }
    };
    
    // Mark peer as online (we received a valid encrypted message)
    if let Ok(mut pm) = PEER_MANAGER.lock() {
        if let Some(ref mut peer_manager) = *pm {
            peer_manager.mark_peer_online(&sender, None);
        }
    }
    
    // Verify signature (Proof of Identity) - like CLI does
    let mut is_verified = false;
    if let Ok(crypto_guard) = CRYPTO.lock() {
        if let Some(ref crypto) = *crypto_guard {
            is_verified = MessageProtocol::verify_message(msg, crypto);
        }
    }
    
    if is_verified {
        println!("[✓ SIGNATURE VERIFIED] Message from {} is authentic.", sender);
    } else {
        println!("[⚠ SIGNATURE FAILED] Could not verify message from {}. It may be faked!", sender);
    }
    
    // If it's a new contact, send a handshake back IMMEDIATELY (non-blocking)
    // This must happen BEFORE decryption to avoid blocking the sender
    if is_new_contact {
        println!("👋 [Flutter] Sending handshake response to new contact {}", sender);
        let sender_clone = sender.clone();
        std::thread::spawn(move || {
            // Send handshake immediately to unblock the sender
            if let Err(e) = send_handshake_to_contact(sender_clone.clone()) {
                println!("⚠ [Flutter] Failed to send handshake to {}: {}", sender_clone, e);
            } else {
                println!("✓ [Flutter] Handshake sent successfully to {}", sender_clone);
            }
        });
    }
    
    // Decrypt the message using ECIES
    if let Ok(crypto_guard) = CRYPTO.lock() {
        if let Some(ref crypto) = *crypto_guard {
            println!("[DEBUG Flutter] Attempting ECIES decryption from {}", sender);
            match crypto.decrypt_message(&encrypted_data) {
                Ok(decrypted_text) => {
                    println!("\n[✓ DECRYPTED] Message from {}: {}", sender, decrypted_text);
                    println!("[DEBUG] Message ID: {}", msg.id);
                    println!("[DEBUG] Timestamp: {}", msg.timestamp);
                    
                    // Save to storage
                    if let Ok(storage_guard) = STORAGE.lock() {
                        if let Some(storage) = storage_guard.as_ref() {
                            let payload = serde_json::json!({"text": &decrypted_text});
                            match storage.save_message(
                                &msg.id,
                                "text",
                                msg.sender_id.as_deref(),
                                msg.recipient_id.as_deref(),
                                &payload,
                                msg.timestamp,
                                false,
                            ) {
                                Ok(_) => println!("[✓] Message saved to database"),
                                Err(e) => println!("[✗] Failed to save message: {}", e),
                            }
                        }
                    }
                    
                    // Increment new message counter
                    if let Ok(mut count) = NEW_MESSAGE_COUNT.lock() {
                        *count += 1;
                        println!("[DEBUG] New message count incremented to: {}", *count);
                    }
                }
                Err(e) => {
                    println!("✗ [Flutter] ECIES decryption error from {}: {}", sender, e);
                }
            }
        }
    }
}

/// Handle encrypted text messages - STRICT: Only encrypted messages accepted
fn handle_text_message(msg: &ProtocolMessage) {
    // sender_id is guaranteed to exist (checked in handle_incoming_message)
    let sender = msg.sender_id.as_ref().unwrap().clone();
    
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
    let encrypted_data = match serde_json::from_value::<gumnam::crypto::EncryptedData>(data.clone()) {
        Ok(ed) => ed,
        Err(_) => {
            println!("⚠ [Flutter] Rejected invalid encrypted data format from {}", sender);
            return;
        }
    };
    
    // Check if sender is a known contact, if not create one
    {
        let storage_guard = STORAGE.lock().ok();
        let contact_exists = storage_guard.as_ref()
            .and_then(|s| s.as_ref())
            .and_then(|s| s.get_contact(&sender).ok())
            .flatten()
            .is_some();
        
        if !contact_exists {
            println!("📱 [Flutter] New contact detected: {}", sender);
            if let Ok(storage_guard) = STORAGE.lock() {
                if let Some(storage) = storage_guard.as_ref() {
                    // Sanitize nickname to only use ASCII characters to avoid UTF-16 issues
                    let safe_prefix = sender.chars()
                        .filter(|c| c.is_ascii_alphanumeric())
                        .take(12)
                        .collect::<String>();
                    let default_nickname = if safe_prefix.is_empty() {
                        "Contact".to_string()
                    } else {
                        safe_prefix
                    };
                    let _ = storage.add_contact(&sender, Some(&default_nickname), None);
                    println!("✓ [Flutter] Created new contact: {}", default_nickname);
                }
            }
        }
    }
    
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

/// Handle encrypted file/media messages
fn handle_file_message(msg: &ProtocolMessage) {
    let sender = msg.sender_id.as_ref().unwrap().clone();
    
    // Strict: Must have data field
    let data = match msg.payload.get("data") {
        Some(d) => d,
        None => {
            println!("⚠ [Flutter] Rejected encrypted media without data from {}", sender);
            return;
        }
    };
    
    // Strict: Must be valid EncryptedData
    let encrypted_data = match serde_json::from_value::<gumnam::crypto::EncryptedData>(data.clone()) {
        Ok(ed) => ed,
        Err(_) => {
            println!("⚠ [Flutter] Rejected invalid encrypted media data from {}", sender);
            return;
        }
    };
    
    // Decrypt
    if let Ok(crypto_guard) = CRYPTO.lock() {
        if let Some(ref crypto) = *crypto_guard {
             match crypto.decrypt_message(&encrypted_data) {
                Ok(decrypted_content) => {
                    // Content is Base64 encoded file data (plus optional metadata if we were fancy, but here just raw base64?)
                    // The `send_file` sends Base64 string as the encrypted payload.
                    // So `decrypted_content` IS the Base64 string.
                    
                    let type_str = msg.msg_type.as_str();
                    println!("← [Flutter] Received {} from {}", type_str, sender);
                    
                    // Save to storage
                    if let Ok(storage_guard) = STORAGE.lock() {
                        if let Some(storage) = storage_guard.as_ref() {
                            // We save the BASE64 string as the "text" payload in DB for simplicity? 
                            // Yes, or a separate field. `save_message` takes `payload` (JSON).
                            // We can store it in "text" field or "content" field.
                            // `MessageInfo` maps `payload["text"]` to `text`.
                            // So if we want UI to see it, we should put it in "text" or update `get_messages` to look elsewhere.
                            // Start with "text" containing the base64 data.
                            // Ideally we prefix it or use metadata?
                            // Let's use `payload = {"text": base64_data, "filename": ...}` if we had filename.
                            // For now simple: text = base64.
                            
                            let payload = serde_json::json!({
                                "text": &decrypted_content,
                                "is_file": true // Marker
                            });
                            
                            let _ = storage.save_message(
                                &msg.id,
                                type_str,
                                msg.sender_id.as_deref(),
                                msg.recipient_id.as_deref(),
                                &payload,
                                msg.timestamp,
                                false,
                            );
                        }
                    }
                    
                     if let Ok(mut count) = NEW_MESSAGE_COUNT.lock() {
                        *count += 1;
                    }
                }
                Err(e) => println!("✗ [Flutter] Media decryption error: {}", e),
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
        
        // ECIES: Encrypt using recipient's onion address (no public key exchange needed)
        let crypto_guard = CRYPTO.lock().unwrap();
        let crypto = crypto_guard.as_ref().ok_or_else(|| {
            println!("[DEBUG] ERROR: Crypto not initialized!");
            anyhow::anyhow!("Cannot send message: Crypto not initialized.")
        })?;
        
        // ECIES encryption: derive recipient's X25519 public key from their onion address
        let encrypted_data = crypto.encrypt_message(&message, &onion_address)
            .map_err(|e| {
                println!("[DEBUG] ERROR: ECIES encryption failed: {}", e);
                anyhow::anyhow!("Encryption failed: {}. Message NOT sent.", e)
            })?;
        
        println!("[DEBUG] Message encrypted with ECIES successfully");
        
        // Create encrypted protocol message with sender_id
        let mut msg = MessageProtocol::wrap_encrypted_message(
            &encrypted_data,
            &my_address,
            &onion_address,
        );
        
        // SIGN the message (Proof of Identity) - CRITICAL FOR VERIFICATION
        MessageProtocol::sign_message(&mut msg, crypto)
            .map_err(|e| {
                println!("[DEBUG] ERROR: Message signing failed: {}", e);
                anyhow::anyhow!("Signing failed: {}", e)
            })?;
        
        println!("[DEBUG] Message signed successfully");
        
        let msg_id = msg.id.clone();
        let timestamp = msg.timestamp;
        let msg_json = msg.to_json().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        
        println!("[DEBUG] Protocol message JSON length: {}", msg_json.len());
        
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
        println!("[DEBUG] Sending ECIES encrypted message via Tor...");
        let result = service.send_message(&onion_address, &msg_json);
        println!("[DEBUG] Send result: {:?}", result.is_ok());
        result.map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
        println!("[DEBUG] ERROR: Tor service not started!");
        Err(anyhow::anyhow!("Tor service not started"))
    }

}

pub fn send_file(onion_address: String, file_path: String, file_type: String) -> anyhow::Result<bool> {
    println!("[DEBUG] send_file called: path={}, type={}", file_path, file_type);
    
    // Validate file
    let path = Path::new(&file_path);
    if !path.exists() {
        return Err(anyhow::anyhow!("File not found"));
    }
    
    let metadata = fs::metadata(path)?;
    if metadata.len() > 5 * 1024 * 1024 { // 5MB limit
         return Err(anyhow::anyhow!("File too large (max 5MB)"));
    }

    let file_content = fs::read(path)?;
    let encoded = BASE64_STANDARD.encode(file_content);
    
    // Determine MessageType
    let msg_type = match file_type.as_str() {
        "image" => MessageType::Image,
        "audio" => MessageType::Audio,
         _ => MessageType::File,
    };
    
    let service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.as_ref() {
        let my_address = service.get_onion_address().unwrap_or_default();
        
        // ECIES: Encrypt using recipient's onion address (no public key exchange needed)
        let crypto_guard = CRYPTO.lock().unwrap();
        let crypto = crypto_guard.as_ref().ok_or_else(|| anyhow::anyhow!("Crypto not initialized"))?;
        
        // ECIES encryption: derive recipient's X25519 public key from their onion address
        let encrypted_data = crypto.encrypt_message(&encoded, &onion_address)
            .map_err(|e| anyhow::anyhow!("ECIES encryption failed: {}", e))?;
            
        // Wrap in protocol message
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("encrypted".to_string(), serde_json::Value::Bool(true));
        payload.insert("data".to_string(), serde_json::to_value(encrypted_data).unwrap());
        
        let mut msg = ProtocolMessage::new(
            msg_type,
            payload,
            Some(my_address.clone()),
            Some(onion_address.clone()),
        );
        
        // SIGN the message (Proof of Identity)
        MessageProtocol::sign_message(&mut msg, crypto)
            .map_err(|e| anyhow::anyhow!("File message signing failed: {}", e))?;
        
        drop(crypto_guard);
        
        let msg_json = msg.to_json().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        
        // Save to storage
        let storage_guard = STORAGE.lock().unwrap();
        if let Some(storage) = storage_guard.as_ref() {
            let payload = serde_json::json!({
                "text": encoded, // Store base64 content in text field for now
                "is_file": true,
                "local_path": file_path // Store local path so we don't need to re-download/decode our own send
            });
            let _ = storage.save_message(
                &msg.id,
                msg_type.as_str(),
                Some(&my_address),
                Some(&onion_address),
                &payload,
                msg.timestamp,
                true,
            );
        }
        drop(storage_guard);
        
        let result = service.send_message(&onion_address, &msg_json);
        result.map_err(|e| anyhow::anyhow!(e.to_string()))
    } else {
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
        public_key: None,
    });
    
    if let Some(storage) = storage_guard.as_ref() {
        let db_contacts = storage.get_all_contacts().map_err(|e| anyhow::anyhow!(e.to_string()))?;
        for c in db_contacts {
            // Sanitize nickname when reading from DB to fix existing bad data
            let raw_nickname = c.nickname.unwrap_or_else(|| "Unknown".to_string());
            let sanitized_nickname = raw_nickname.chars()
                .filter(|ch| ch.is_ascii_alphanumeric() || ch.is_whitespace() || *ch == '-' || *ch == '_')
                .collect::<String>();
            let final_nickname = if sanitized_nickname.trim().is_empty() {
                "Contact".to_string()
            } else {
                sanitized_nickname
            };
            
            contacts.push(ContactInfo {
                onion_address: c.onion_address,
                nickname: final_nickname,
                last_seen: c.last_seen,
                public_key: c.public_key,
            });
        }
    }
    Ok(contacts)
}

pub fn add_contact(onion_address: String, nickname: String) -> anyhow::Result<bool> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        // STRICT VALIDATION: Ensure it's a valid v3 onion address and we can derive a pubkey
        if let Err(e) = gumnam::crypto::CryptoHandler::onion_to_pubkey(&onion_address) {
            println!("⚠ [Flutter] Rejected invalid onion address: {} ({})", onion_address, e);
            return Err(anyhow::anyhow!("Invalid onion address: {}", e));
        }

        storage.add_contact(&onion_address, Some(&nickname), None)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        
        // Send handshake to the new contact
        drop(storage_guard);  // Release lock before sending
        let address_clone = onion_address.clone();
        std::thread::spawn(move || {
            if let Err(e) = send_handshake_to_contact(address_clone) {
                println!("⚠ [Flutter] Failed to send handshake: {}", e);
            }
        });
        
        Ok(true)
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}

/// Send a handshake message to a contact (ECIES - no public key exchange needed)
pub fn send_handshake_to_contact(onion_address: String) -> anyhow::Result<bool> {
    println!("→ [Flutter ECIES] Sending handshake to: {}", onion_address);
    
    // Get our onion address
    let our_onion = get_onion_address();
    if our_onion.is_empty() {
        return Err(anyhow::anyhow!("Tor not started"));
    }
    
    // Create handshake message - ECIES doesn't need public key exchange
    let mut handshake = MessageProtocol::create_handshake_message(&our_onion, false);
    
    // SIGN the handshake message
    if let Ok(crypto_guard) = CRYPTO.lock() {
        if let Some(ref crypto) = *crypto_guard {
            MessageProtocol::sign_message(&mut handshake, crypto)
                .map_err(|e| anyhow::anyhow!("Failed to sign handshake: {}", e))?;
        }
    }
    
    let json = handshake.to_json().map_err(|e| anyhow::anyhow!(e.to_string()))?;
    
    // Send via Tor
    let service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.as_ref() {
        match service.send_message(&onion_address, &json) {
            Ok(_) => {
                println!("✓ [Flutter ECIES] Handshake sent to {}", onion_address);
                Ok(true)
            }
            Err(e) => {
                println!("✗ [Flutter] Failed to send handshake: {}", e);
                Err(anyhow::anyhow!(e.to_string()))
            }
        }
    } else {
        Err(anyhow::anyhow!("Tor service not started"))
    }
}

/// Get detailed contact information for the contact info dialog
pub fn get_contact_details(onion_address: String) -> anyhow::Result<ContactDetails> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        // Get contact info
        let contact = storage.get_contact(&onion_address)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("Contact not found"))?;
        
        // Get message statistics
        let messages = storage.get_messages(Some(&onion_address), 1000)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        
        let total_messages = messages.len() as i32;
        let first_message_time = messages.last().map(|m| m.timestamp);
        let last_message_time = messages.first().map(|m| m.timestamp);
        
        Ok(ContactDetails {
            onion_address: contact.onion_address,
            nickname: contact.nickname.unwrap_or_else(|| "Unknown".to_string()),
            public_key: contact.public_key,
            last_seen: contact.last_seen,
            first_message_time,
            last_message_time,
            total_messages,
        })
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}

/// Update a contact's nickname
pub fn update_contact_nickname(onion_address: String, nickname: String) -> anyhow::Result<bool> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        // Get existing contact to preserve public key
        let existing = storage.get_contact(&onion_address)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
            .ok_or_else(|| anyhow::anyhow!("Contact not found"))?;
        
        // Update with new nickname, preserving public key
        storage.add_contact(&onion_address, Some(&nickname), existing.public_key.as_deref())
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
            msg_type: Some(m.msg_type),
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
            msg_type: Some("web_message".to_string()),
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

// Delete a single message by ID
pub fn delete_message(message_id: String) -> anyhow::Result<bool> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        storage.delete_message(&message_id)
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

/// Fix all existing contacts with bad nicknames (sanitize them)
pub fn fix_contact_nicknames() -> anyhow::Result<i32> {
    let storage_guard = STORAGE.lock().unwrap();
    if let Some(storage) = storage_guard.as_ref() {
        let contacts = storage.get_all_contacts()
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        let mut fixed_count = 0;
        
        for contact in contacts {
            if let Some(nickname) = &contact.nickname {
                // Sanitize the nickname
                let sanitized = nickname.chars()
                    .filter(|ch| ch.is_ascii_alphanumeric() || ch.is_whitespace() || *ch == '-' || *ch == '_')
                    .collect::<String>();
                
                // If it changed, update it
                if sanitized != *nickname || sanitized.trim().is_empty() {
                    let new_nickname = if sanitized.trim().is_empty() {
                        "Contact".to_string()
                    } else {
                        sanitized
                    };
                    
                    println!("[Fix] Updating contact {} nickname: '{}' -> '{}'", 
                             contact.onion_address, nickname, new_nickname);
                    
                    let _ = storage.add_contact(
                        &contact.onion_address,
                        Some(&new_nickname),
                        contact.public_key.as_deref()
                    );
                    fixed_count += 1;
                }
            }
        }
        
        println!("[✓] Fixed {} contact nicknames", fixed_count);
        Ok(fixed_count)
    } else {
        Err(anyhow::anyhow!("Storage not initialized"))
    }
}
