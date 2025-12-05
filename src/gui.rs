//! GUI components using iced framework
//!
//! Port of Python tor_messenger_gui.py (Tkinter -> iced)

use chrono::Local;
use iced::widget::{button, column, container, progress_bar, row, scrollable, text, text_input, Column, Space};
use iced::{Element, Length, Task, Theme};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;

use crate::crypto::{CryptoHandler, EncryptedData};
use crate::message::{Message as ProtocolMessage, MessageProtocol, MessageType};
use crate::peer::PeerManager;
use crate::storage::MessageStorage;
use crate::tor_service::TorService;

/// Log entry with type for color coding
#[derive(Debug, Clone)]
pub struct LogEntry {
    pub timestamp: String,
    pub message: String,
    pub msg_type: LogType,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LogType {
    System,
    Sent,
    Received,
    Error,
    #[allow(dead_code)]
    Info,
}

impl LogType {
    pub fn prefix(&self) -> &'static str {
        match self {
            LogType::System => "[SYS]",
            LogType::Sent => "[→]",
            LogType::Received => "[←]",
            LogType::Error => "[ERR]",
            LogType::Info => "[INFO]",
        }
    }
}

/// GUI messages (events)
#[derive(Debug, Clone)]
pub enum GuiMessage {
    // Tor status updates
    TorStarted(Option<String>),
    TorFailed,
    #[allow(dead_code)]
    BootstrapProgress(u32, String),
    
    // User input
    ContactAddressChanged(String),
    NicknameChanged(String),
    RecipientChanged(String),
    MessageInputChanged(String),
    
    // Actions
    AddContact,
    SendMessage,
    CopyOnionAddress,
    
    // Incoming messages
    #[allow(dead_code)]
    IncomingMessage(String),
    
    // Tick for periodic updates
    Tick,
}

/// Application state
pub struct TorMessengerApp {
    // Backend components
    crypto: Arc<Mutex<CryptoHandler>>,
    storage: Arc<Mutex<MessageStorage>>,
    peer_manager: Arc<Mutex<PeerManager>>,
    tor_service: Arc<TorService>,
    
    // State
    onion_address: Option<String>,
    #[allow(dead_code)]
    is_running: bool,
    bootstrap_percentage: u32,
    bootstrap_status: String,
    
    // UI state
    contact_address_input: String,
    nickname_input: String,
    recipient_input: String,
    message_input: String,
    log_entries: Vec<LogEntry>,
    
    // Message channels
    #[allow(dead_code)]
    message_sender: Sender<String>,
    message_receiver: Arc<Mutex<Receiver<String>>>,
}

impl TorMessengerApp {
    /// Create a new application instance
    pub fn new() -> (Self, Task<GuiMessage>) {
        // Create message channel for incoming messages
        let (tx, rx) = mpsc::channel();
        
        // Initialize backend components
        let crypto = Arc::new(Mutex::new(
            CryptoHandler::new().expect("Failed to initialize crypto"),
        ));
        let storage = Arc::new(Mutex::new(
            MessageStorage::new().expect("Failed to initialize storage"),
        ));
        let peer_manager = Arc::new(Mutex::new(PeerManager::new(Arc::clone(&storage))));
        
        // Create Tor service with message handler
        let tx_clone = tx.clone();
        let tor_service = Arc::new(TorService::new(Some(Box::new(move |msg: String| {
            let _ = tx_clone.send(msg);
        }))));
        
        let app = Self {
            crypto,
            storage,
            peer_manager,
            tor_service,
            onion_address: None,
            is_running: false,
            bootstrap_percentage: 0,
            bootstrap_status: "Starting...".to_string(),
            contact_address_input: String::new(),
            nickname_input: String::new(),
            recipient_input: String::new(),
            message_input: String::new(),
            log_entries: Vec::new(),
            message_sender: tx,
            message_receiver: Arc::new(Mutex::new(rx)),
        };
        
        // Return app with startup command
        (app, Task::none())
    }
    
    /// Initialize and start Tor (called after app is created)
    pub fn start_tor(&mut self) -> Task<GuiMessage> {
        self.log_message("🔄 Starting Tor service...", LogType::System);
        
        let tor_service = Arc::clone(&self.tor_service);
        
        Task::perform(
            async move {
                // Start Tor in blocking thread
                let result = tokio::task::spawn_blocking(move || {
                    if tor_service.start().is_ok() {
                        tor_service.get_onion_address()
                    } else {
                        None
                    }
                })
                .await
                .ok()
                .flatten();
                
                result
            },
            |result| {
                if result.is_some() {
                    GuiMessage::TorStarted(result)
                } else {
                    GuiMessage::TorFailed
                }
            },
        )
    }
    
    /// Handle a GUI message/event
    pub fn update(&mut self, message: GuiMessage) -> Task<GuiMessage> {
        match message {
            GuiMessage::TorStarted(onion) => {
                self.onion_address = onion.clone();
                self.is_running = true;
                
                if let Some(ref addr) = onion {
                    self.log_message(&format!("✓ Your onion address: {}", addr), LogType::System);
                    self.log_message("✓ Ready to send and receive messages!", LogType::System);
                } else {
                    self.log_message("⚠️ Tor is still bootstrapping. Your address will appear soon.", LogType::System);
                }
            }
            
            GuiMessage::TorFailed => {
                self.log_message("✗ Failed to start Tor. Please check your Tor installation.", LogType::Error);
            }
            
            GuiMessage::BootstrapProgress(percentage, status) => {
                self.bootstrap_percentage = percentage;
                self.bootstrap_status = status;
                
                if percentage == 100 {
                    self.log_message("✅ Your .onion link is now accessible from mobile and other devices!", LogType::System);
                }
            }
            
            GuiMessage::ContactAddressChanged(value) => {
                self.contact_address_input = value;
            }
            
            GuiMessage::NicknameChanged(value) => {
                self.nickname_input = value;
            }
            
            GuiMessage::RecipientChanged(value) => {
                self.recipient_input = value;
            }
            
            GuiMessage::MessageInputChanged(value) => {
                self.message_input = value;
            }
            
            GuiMessage::AddContact => {
                let onion = self.contact_address_input.trim().to_string();
                let nickname = if self.nickname_input.trim().is_empty() {
                    onion.clone()
                } else {
                    self.nickname_input.trim().to_string()
                };
                
                if onion.is_empty() {
                    self.log_message("✗ Please enter an onion address", LogType::Error);
                    return Task::none();
                }
                
                // Scope the borrow properly
                let add_result = {
                    if let Ok(pm) = self.peer_manager.lock() {
                        pm.add_peer(&onion, Some(&nickname), None).is_ok()
                    } else {
                        false
                    }
                };
                
                if add_result {
                    self.log_message(&format!("✓ Added contact: {} ({})", nickname, onion), LogType::System);
                    
                    // Initiate handshake
                    let my_onion = self.onion_address.clone().unwrap_or_else(|| "unknown".to_string());
                    let public_key = self.crypto.lock().unwrap().get_public_key_pem().unwrap_or_default();
                    let handshake = MessageProtocol::create_handshake_message(&my_onion, &public_key);
                    
                    if let Ok(json) = handshake.to_json() {
                        let tor = Arc::clone(&self.tor_service);
                        let peer_onion = onion.clone();
                        thread::spawn(move || {
                            if tor.send_message(&peer_onion, &json).is_ok() {
                                println!("✓ Handshake sent to {}", peer_onion);
                            }
                        });
                    }
                    
                    // Clear inputs
                    self.contact_address_input.clear();
                    self.nickname_input.clear();
                } else {
                    self.log_message("✗ Failed to add contact", LogType::Error);
                }
            }
            
            GuiMessage::SendMessage => {
                let recipient = self.recipient_input.trim().to_string();
                let message_text = self.message_input.trim().to_string();
                
                if recipient.is_empty() || message_text.is_empty() {
                    self.log_message("✗ Please enter recipient and message", LogType::Error);
                    return Task::none();
                }
                
                if self.onion_address.is_none() {
                    self.log_message("✗ Tor is still starting. Please wait.", LogType::Error);
                    return Task::none();
                }
                
                // Get recipient's public key
                let public_key = self.peer_manager.lock().unwrap().get_peer_public_key(&recipient);
                
                if public_key.is_none() {
                    self.log_message("✗ No public key for recipient. Adding contact and initiating handshake...", LogType::System);
                    
                    // Add peer and send handshake
                    if let Ok(pm) = self.peer_manager.lock() {
                        let _ = pm.add_peer(&recipient, None, None);
                    }
                    
                    let my_onion = self.onion_address.clone().unwrap_or_default();
                    let pk = self.crypto.lock().unwrap().get_public_key_pem().unwrap_or_default();
                    let handshake = MessageProtocol::create_handshake_message(&my_onion, &pk);
                    
                    if let Ok(json) = handshake.to_json() {
                        let tor = Arc::clone(&self.tor_service);
                        let peer = recipient.clone();
                        thread::spawn(move || {
                            let _ = tor.send_message(&peer, &json);
                        });
                    }
                    
                    return Task::none();
                }
                
                // Encrypt and send message
                let encrypt_result = {
                    let crypto = self.crypto.lock().unwrap();
                    crypto.encrypt_message(&message_text, &public_key.unwrap())
                };
                
                match encrypt_result {
                    Ok(encrypted_data) => {
                        let my_onion = self.onion_address.clone().unwrap_or_default();
                        let msg = MessageProtocol::wrap_encrypted_message(&encrypted_data, &my_onion, &recipient);
                        
                        if let Ok(json) = msg.to_json() {
                            let tor = Arc::clone(&self.tor_service);
                            let peer = recipient.clone();
                            let storage = Arc::clone(&self.storage);
                            let msg_id = msg.id.clone();
                            let timestamp = msg.timestamp;
                            let sender = my_onion.clone();
                            let text_clone = message_text.clone();
                            
                            thread::spawn(move || {
                                if tor.send_message(&peer, &json).is_ok() {
                                    // Save to storage
                                    if let Ok(s) = storage.lock() {
                                        let payload = serde_json::json!({"text": text_clone});
                                        let _ = s.save_message(
                                            &msg_id,
                                            "text",
                                            Some(&sender),
                                            Some(&peer),
                                            &payload,
                                            timestamp,
                                            true,
                                        );
                                    }
                                }
                            });
                            
                            self.log_message(&format!("→ You to {}: {}", recipient, message_text), LogType::Sent);
                            self.message_input.clear();
                        }
                    }
                    Err(e) => {
                        self.log_message(&format!("✗ Encryption error: {}", e), LogType::Error);
                    }
                }
            }
            
            GuiMessage::CopyOnionAddress => {
                // Note: Clipboard support requires additional crate in iced
                if let Some(ref addr) = self.onion_address {
                    self.log_message(&format!("📋 Onion address: {} (copy manually)", addr), LogType::System);
                }
            }
            
            GuiMessage::IncomingMessage(msg_str) => {
                self.handle_incoming_message(&msg_str);
            }
            
            GuiMessage::Tick => {
                // Check for incoming messages  
                let messages: Vec<String> = {
                    if let Ok(rx) = self.message_receiver.lock() {
                        let mut msgs = Vec::new();
                        while let Ok(msg) = rx.try_recv() {
                            msgs.push(msg);
                        }
                        msgs
                    } else {
                        Vec::new()
                    }
                };
                
                for msg in messages {
                    self.handle_incoming_message(&msg);
                }
                
                // Update onion address if not set
                if self.onion_address.is_none() {
                    self.onion_address = self.tor_service.get_onion_address();
                }
            }
        }
        
        Task::none()
    }
    
    /// Handle incoming message from peer
    fn handle_incoming_message(&mut self, message_str: &str) {
        // Try to parse as JSON
        if let Ok(msg_data) = serde_json::from_str::<serde_json::Value>(message_str) {
            // Check if it's a web message
            if msg_data.get("type").and_then(|v| v.as_str()) == Some("web_message") {
                let sender = msg_data.get("sender").and_then(|v| v.as_str()).unwrap_or("Anonymous");
                let text_content = msg_data.get("text").and_then(|v| v.as_str()).unwrap_or("");
                self.log_message(&format!("🌐 Web message from '{}': {}", sender, text_content), LogType::Received);
                return;
            }
            
            // Handle regular protocol messages
            if let Ok(msg) = ProtocolMessage::from_json(message_str) {
                if !MessageProtocol::validate_message(&msg) {
                    return;
                }
                
                match msg.msg_type {
                    MessageType::Handshake => {
                        self.handle_handshake(&msg);
                    }
                    MessageType::Text => {
                        self.handle_text_message(&msg);
                    }
                    _ => {}
                }
            }
        } else {
            // Raw message
            self.log_message(&format!("← Raw message: {}", message_str), LogType::Received);
        }
    }
    
    /// Handle handshake message
    fn handle_handshake(&mut self, msg: &ProtocolMessage) {
        if let Some(sender_id) = &msg.sender_id {
            if let Some(public_key) = msg.payload.get("public_key").and_then(|v| v.as_str()) {
                if let Ok(mut pm) = self.peer_manager.lock() {
                    let _ = pm.add_peer(sender_id, None, Some(public_key));
                    pm.mark_peer_online(sender_id, None);
                }
                self.log_message(&format!("✓ Handshake complete with {}", sender_id), LogType::System);
            }
        }
    }
    
    /// Handle text message
    fn handle_text_message(&mut self, msg: &ProtocolMessage) {
        if msg.payload.get("encrypted").and_then(|v| v.as_bool()) == Some(true) {
            if let Some(data) = msg.payload.get("data") {
                if let Ok(encrypted_data) = serde_json::from_value::<EncryptedData>(data.clone()) {
                    // Decrypt in a separate scope to avoid borrow issues
                    let decrypt_result = {
                        let crypto = self.crypto.lock().unwrap();
                        crypto.decrypt_message(&encrypted_data)
                    };
                    
                    match decrypt_result {
                        Ok(decrypted_text) => {
                            let sender = msg.sender_id.as_deref().unwrap_or("Unknown");
                            
                            // Save to storage
                            if let Ok(storage) = self.storage.lock() {
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
                            
                            self.log_message(&format!("← {}: {}", sender, decrypted_text), LogType::Received);
                        }
                        Err(e) => {
                            self.log_message(&format!("✗ Decryption error: {}", e), LogType::Error);
                        }
                    }
                }
            }
        }
    }
    
    /// Add a log entry
    fn log_message(&mut self, message: &str, msg_type: LogType) {
        let timestamp = Local::now().format("%H:%M:%S").to_string();
        self.log_entries.push(LogEntry {
            timestamp,
            message: message.to_string(),
            msg_type,
        });
        
        // Keep only last 1000 entries
        if self.log_entries.len() > 1000 {
            self.log_entries.remove(0);
        }
    }
    
    /// Build the view
    pub fn view(&self) -> Element<GuiMessage> {
        // === Status Section ===
        let onion_text: String = self.onion_address.clone().unwrap_or_else(|| "Starting Tor...".to_string());
        
        let status_section = column![
            text("Status").size(18),
            row![
                text("Your Onion Address: ").size(14),
                text(onion_text).size(14),
                Space::with_width(Length::Fixed(10.0)),
                button("Copy").on_press(GuiMessage::CopyOnionAddress),
            ]
            .spacing(5),
            row![
                text("Tor Bootstrap: ").size(14),
                progress_bar(0.0..=100.0, self.bootstrap_percentage as f32)
                    .width(Length::Fixed(300.0)),
                text(format!(" {}% - {}", self.bootstrap_percentage, self.bootstrap_status)).size(12),
            ]
            .spacing(5),
        ]
        .spacing(10)
        .padding(10);
        
        // === Contact Section ===
        let contact_section = column![
            text("Add Contact").size(18),
            row![
                text("Onion Address:").size(14),
                text_input("Enter .onion address", &self.contact_address_input)
                    .on_input(GuiMessage::ContactAddressChanged)
                    .width(Length::Fixed(400.0)),
            ]
            .spacing(10),
            row![
                text("Nickname:").size(14),
                text_input("Optional nickname", &self.nickname_input)
                    .on_input(GuiMessage::NicknameChanged)
                    .width(Length::Fixed(200.0)),
                Space::with_width(Length::Fixed(10.0)),
                button("Add Contact").on_press(GuiMessage::AddContact),
            ]
            .spacing(10),
        ]
        .spacing(10)
        .padding(10);
        
        // === Messages Section ===
        let messages: Vec<Element<GuiMessage>> = self
            .log_entries
            .iter()
            .map(|entry| {
                text(format!("[{}] {} {}", entry.timestamp, entry.msg_type.prefix(), entry.message))
                    .size(13)
                    .into()
            })
            .collect();
        
        let messages_column: Column<'_, GuiMessage> = Column::with_children(messages)
            .spacing(2)
            .padding(5);
        
        let messages_section = column![
            text("Messages").size(18),
            container(scrollable(messages_column).height(Length::Fixed(300.0)))
                .width(Length::Fill)
                .height(Length::Fixed(320.0)),
        ]
        .spacing(10)
        .padding(10);
        
        // === Send Message Section ===
        let send_section = column![
            text("Send Message").size(18),
            row![
                text("To:").size(14),
                text_input("Recipient .onion address", &self.recipient_input)
                    .on_input(GuiMessage::RecipientChanged)
                    .width(Length::Fixed(400.0)),
            ]
            .spacing(10),
            row![
                text("Message:").size(14),
                text_input("Type your message", &self.message_input)
                    .on_input(GuiMessage::MessageInputChanged)
                    .on_submit(GuiMessage::SendMessage)
                    .width(Length::Fixed(400.0)),
                Space::with_width(Length::Fixed(10.0)),
                button("Send").on_press(GuiMessage::SendMessage),
            ]
            .spacing(10),
        ]
        .spacing(10)
        .padding(10);
        
        // === Main Layout ===
        let content = column![
            status_section,
            contact_section,
            messages_section,
            send_section,
        ]
        .spacing(10)
        .padding(20);
        
        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    }
    
    /// Get the application theme
    pub fn theme(&self) -> Theme {
        Theme::Dark
    }
    
    /// Get the application title
    pub fn title(&self) -> String {
        "Tor Serverless Messenger".to_string()
    }
}
