use flutter_rust_bridge::frb;
use std::sync::{Arc, Mutex};
use std::collections::VecDeque;
use once_cell::sync::Lazy;
use tor_messenger::tor_service::TorService;
use tor_messenger::storage::MessageStorage;

// Global state
static TOR_SERVICE: Lazy<Arc<Mutex<Option<TorService>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));
static STORAGE: Lazy<Arc<Mutex<Option<MessageStorage>>>> = Lazy::new(|| Arc::new(Mutex::new(None)));

// Web messages queue for real-time updates
static WEB_MESSAGES: Lazy<Arc<Mutex<VecDeque<WebMessageInfo>>>> = Lazy::new(|| Arc::new(Mutex::new(VecDeque::new())));

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
    
    let mut service_guard = TOR_SERVICE.lock().unwrap();
    if service_guard.is_none() {
        // Create message handler that saves web messages
        let handler: Box<dyn Fn(String) + Send + Sync> = Box::new(|msg_str: String| {
            // Parse web message JSON
            if let Ok(msg_data) = serde_json::from_str::<serde_json::Value>(&msg_str) {
                if msg_data.get("type").and_then(|v| v.as_str()) == Some("web_message") {
                    let sender = msg_data.get("sender").and_then(|v| v.as_str()).unwrap_or("Anonymous");
                    let text = msg_data.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    let timestamp_str = msg_data.get("timestamp").and_then(|v| v.as_str()).unwrap_or("");
                    
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
                        // Keep only last 100 messages in queue
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
                    
                    println!("📨 [Flutter] Web message saved from '{}': {}", sender, text);
                }
            }
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

pub fn send_message(onion_address: String, message: String) -> anyhow::Result<bool> {
    let service_guard = TOR_SERVICE.lock().unwrap();
    if let Some(service) = service_guard.as_ref() {
        // Save sent message to storage
        let storage_guard = STORAGE.lock().unwrap();
        if let Some(storage) = storage_guard.as_ref() {
            let msg_id = uuid::Uuid::new_v4().to_string();
            let payload = serde_json::json!({"text": message});
            let my_address = service.get_onion_address().unwrap_or_default();
            let _ = storage.save_message(
                &msg_id,
                "text",
                Some(&my_address),
                Some(&onion_address),
                &payload,
                chrono::Utc::now().timestamp(),
                true,
            );
        }
        service.send_message(&onion_address, &message).map_err(|e| anyhow::anyhow!(e.to_string()))
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
