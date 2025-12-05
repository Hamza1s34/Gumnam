//! CLI (headless) mode for Tor Messenger
//!
//! Run without GUI - just the Tor service with terminal output

use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::crypto::CryptoHandler;
use crate::message::MessageProtocol;
use crate::peer::PeerManager;
use crate::storage::MessageStorage;
use crate::tor_service::TorService;

/// Run the messenger in CLI/headless mode
pub fn run_cli() {
    println!("╔══════════════════════════════════════════════════════════╗");
    println!("║          Tor Serverless Messenger - CLI Mode             ║");
    println!("╚══════════════════════════════════════════════════════════╝");
    println!();

    // Check for restricted environments (Codespaces, containers, etc.)
    check_environment_warnings();

    // Initialize components
    println!("[*] Initializing crypto handler...");
    let crypto = Arc::new(Mutex::new(
        CryptoHandler::new().expect("Failed to initialize crypto"),
    ));

    println!("[*] Initializing storage...");
    let storage = Arc::new(Mutex::new(
        MessageStorage::new().expect("Failed to initialize storage"),
    ));

    println!("[*] Initializing peer manager...");
    let peer_manager = Arc::new(Mutex::new(PeerManager::new(Arc::clone(&storage))));

    println!("[*] Starting Tor service...");
    let tor_service = Arc::new(TorService::new(None));

    // Set bootstrap callback
    tor_service.set_bootstrap_callback(Box::new(|percentage, status| {
        println!("[TOR] Bootstrap: {}% - {}", percentage, status);
    }));

    // Start Tor
    match tor_service.start() {
        Ok(_) => {
            println!("[✓] Tor service started successfully!");
        }
        Err(e) => {
            println!("[✗] Failed to start Tor: {}", e);
            return;
        }
    }

    // Wait for onion address
    println!("[*] Waiting for onion address...");
    let mut attempts = 0;
    let onion_address = loop {
        if let Some(addr) = tor_service.get_onion_address() {
            break addr;
        }
        thread::sleep(Duration::from_secs(1));
        attempts += 1;
        if attempts > 60 {
            println!("[!] Timeout waiting for onion address. Tor may still be bootstrapping.");
            println!("[!] Check ~/.tor_messenger/tor_data/hidden_service/hostname for your address.");
            break "unknown".to_string();
        }
    };

    // Now set up the message handler with access to tor_service for handshake responses
    let crypto_clone = Arc::clone(&crypto);
    let storage_clone = Arc::clone(&storage);
    let peer_manager_clone = Arc::clone(&peer_manager);
    let tor_service_clone = Arc::clone(&tor_service);
    let onion_address_clone = onion_address.clone();
    
    let message_handler = Box::new(move |msg: String| {
        handle_incoming_message(
            &msg, 
            &crypto_clone, 
            &storage_clone, 
            &peer_manager_clone,
            &tor_service_clone,
            &onion_address_clone,
        );
    });
    
    // Set the message handler on the tor service
    tor_service.set_message_handler(message_handler);

    println!();
    println!("╔══════════════════════════════════════════════════════════╗");
    println!("║                    SERVICE READY                         ║");
    println!("╚══════════════════════════════════════════════════════════╝");
    println!();
    println!("Your onion address: {}", onion_address);
    println!();
    println!("Commands:");
    println!("  /add <onion_address> [nickname] - Add a contact");
    println!("  /send <onion_address> <message> - Send a message");
    println!("  /contacts                       - List contacts");
    println!("  /status                         - Show status");
    println!("  /quit                           - Exit");
    println!();

    // Command loop
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    loop {
        print!("> ");
        stdout.flush().unwrap();

        let mut input = String::new();
        if stdin.lock().read_line(&mut input).is_err() {
            continue;
        }

        let input = input.trim();
        if input.is_empty() {
            continue;
        }

        if input.starts_with("/quit") || input.starts_with("/exit") {
            println!("[*] Shutting down...");
            break;
        } else if input.starts_with("/status") {
            println!("Onion Address: {}", onion_address);
            println!("Tor Running: {}", tor_service.is_tor_running());
        } else if input.starts_with("/contacts") {
            if let Ok(pm) = peer_manager.lock() {
                match pm.get_all_peers() {
                    Ok(contacts) => {
                        if contacts.is_empty() {
                            println!("No contacts yet.");
                        } else {
                            println!("Contacts:");
                            for c in contacts {
                                let name = c.nickname.unwrap_or_else(|| "unnamed".to_string());
                                let has_key = if c.public_key.is_some() { "✓" } else { "✗" };
                                println!("  {} [{}] - {}", name, has_key, c.onion_address);
                            }
                        }
                    }
                    Err(e) => println!("[✗] Error: {}", e),
                }
            }
        } else if input.starts_with("/add ") {
            let parts: Vec<&str> = input[5..].splitn(2, ' ').collect();
            let addr = parts[0].trim();
            let nickname = parts.get(1).map(|s| s.trim());

            // Check if adding self
            if addr == onion_address {
                println!("[!] That's your own address. Storing your public key for testing...");
                let my_pk = crypto.lock().unwrap().get_public_key_pem().unwrap_or_default();
                if let Ok(pm) = peer_manager.lock() {
                    match pm.add_peer(addr, nickname, Some(&my_pk)) {
                        Ok(_) => println!("[✓] Added yourself as contact (for testing)"),
                        Err(e) => println!("[✗] Error: {}", e),
                    }
                }
                continue;
            }

            if let Ok(pm) = peer_manager.lock() {
                match pm.add_peer(addr, nickname, None) {
                    Ok(_) => {
                        println!("[✓] Added contact: {}", addr);
                        
                        // Send handshake
                        let pk = crypto.lock().unwrap().get_public_key_pem().unwrap_or_default();
                        let handshake = MessageProtocol::create_handshake_message(&onion_address, &pk);
                        
                        if let Ok(json) = handshake.to_json() {
                            let tor = Arc::clone(&tor_service);
                            let peer = addr.to_string();
                            thread::spawn(move || {
                                println!("[*] Sending handshake to {}...", peer);
                                match tor.send_message(&peer, &json) {
                                    Ok(_) => println!("[✓] Handshake sent to {}", peer),
                                    Err(e) => println!("[✗] Handshake failed: {} (peer may be offline)", e),
                                }
                            });
                        }
                    }
                    Err(e) => println!("[✗] Failed to add contact: {}", e),
                }
            }
        } else if input.starts_with("/test") {
            // Test if our own service is reachable via Tor
            println!("[*] Testing if your hidden service is reachable via Tor...");
            println!("[*] This may take 30-60 seconds on first try...");
            let tor = Arc::clone(&tor_service);
            let addr = onion_address.clone();
            thread::spawn(move || {
                match tor.send_message(&addr, "PING") {
                    Ok(_) => println!("[✓] Your hidden service IS reachable from Tor network!"),
                    Err(e) => println!("[✗] Not reachable yet: {} (wait 2-5 min after bootstrap)", e),
                }
            });
        } else if input.starts_with("/send ") {
            let parts: Vec<&str> = input[6..].splitn(2, ' ').collect();
            if parts.len() < 2 {
                println!("[!] Usage: /send <onion_address> <message>");
                continue;
            }
            
            let recipient = parts[0].trim();
            let message = parts[1].trim();

            // Get recipient's public key
            let public_key = peer_manager.lock().unwrap().get_peer_public_key(recipient);

            if let Some(pk) = public_key {
                let encrypt_result = crypto.lock().unwrap().encrypt_message(message, &pk);
                
                match encrypt_result {
                    Ok(encrypted_data) => {
                        let msg = MessageProtocol::wrap_encrypted_message(
                            &encrypted_data,
                            &onion_address,
                            recipient,
                        );

                        if let Ok(json) = msg.to_json() {
                            let tor = Arc::clone(&tor_service);
                            let peer = recipient.to_string();
                            let msg_text = message.to_string();
                            let storage_c = Arc::clone(&storage);
                            let msg_id = msg.id.clone();
                            let timestamp = msg.timestamp;
                            let sender = onion_address.clone();

                            thread::spawn(move || {
                                match tor.send_message(&peer, &json) {
                                    Ok(_) => {
                                        println!("[→] Sent to {}: {}", peer, msg_text);
                                        // Save to storage
                                        if let Ok(s) = storage_c.lock() {
                                            let payload = serde_json::json!({"text": msg_text});
                                            let _ = s.save_message(
                                                &msg_id, "text", Some(&sender), Some(&peer),
                                                &payload, timestamp, true,
                                            );
                                        }
                                    }
                                    Err(e) => println!("[✗] Send failed: {}", e),
                                }
                            });
                        }
                    }
                    Err(e) => println!("[✗] Encryption error: {}", e),
                }
            } else {
                println!("[!] No public key for {}. Add contact first and wait for handshake.", recipient);
            }
        } else {
            println!("[?] Unknown command. Type /help for commands.");
        }
    }

    // Cleanup
    tor_service.stop();
    println!("[✓] Goodbye!");
}

fn handle_incoming_message(
    message_str: &str,
    crypto: &Arc<Mutex<CryptoHandler>>,
    storage: &Arc<Mutex<MessageStorage>>,
    peer_manager: &Arc<Mutex<PeerManager>>,
    tor_service: &Arc<TorService>,
    our_onion_address: &str,
) {
    use crate::message::{Message as ProtocolMessage, MessageType};

    // Try to parse as JSON
    if let Ok(msg_data) = serde_json::from_str::<serde_json::Value>(message_str) {
        // Check if it's a web message
        if msg_data.get("type").and_then(|v| v.as_str()) == Some("web_message") {
            let sender = msg_data.get("sender").and_then(|v| v.as_str()).unwrap_or("Anonymous");
            let text = msg_data.get("text").and_then(|v| v.as_str()).unwrap_or("");
            println!("\n[🌐 WEB] From '{}': {}", sender, text);
            print!("> ");
            io::stdout().flush().ok();
            return;
        }

        // Handle protocol messages
        println!("[DEBUG] Trying to parse as protocol message...");
        if let Ok(msg) = ProtocolMessage::from_json(message_str) {
            println!("[DEBUG] Parsed message type: {:?}", msg.msg_type);
            match msg.msg_type {
                MessageType::Handshake => {
                    if let Some(sender_id) = &msg.sender_id {
                        println!("[DEBUG] Handshake sender_id: {}", sender_id);
                        if let Some(public_key) = msg.payload.get("public_key").and_then(|v| v.as_str()) {
                            println!("[DEBUG] Got public_key from handshake (length: {})", public_key.len());
                            
                            // Save the sender's public key
                            if let Ok(mut pm) = peer_manager.lock() {
                                let _ = pm.add_peer(sender_id, None, Some(public_key));
                                pm.mark_peer_online(sender_id, None);
                            }
                            println!("\n[✓] Handshake received from: {} (key saved)", sender_id);
                            
                            // ALWAYS send our public key back when we receive a handshake
                            // This ensures the sender gets our key even if we already have theirs
                            let our_pk = crypto.lock().unwrap().get_public_key_pem().unwrap_or_default();
                            let response_handshake = MessageProtocol::create_handshake_message(our_onion_address, &our_pk);
                            
                            if let Ok(json) = response_handshake.to_json() {
                                let tor = Arc::clone(tor_service);
                                let peer = sender_id.clone();
                                thread::spawn(move || {
                                    println!("[*] Sending response handshake to {}...", peer);
                                    match tor.send_message(&peer, &json) {
                                        Ok(_) => println!("[✓] Response handshake sent to {} - key exchange complete!", peer),
                                        Err(e) => println!("[!] Response handshake failed: {}", e),
                                    }
                                    print!("> ");
                                    io::stdout().flush().ok();
                                });
                            }
                            
                            print!("> ");
                            io::stdout().flush().ok();
                        }
                    }
                }
                MessageType::Text => {
                    if msg.payload.get("encrypted").and_then(|v| v.as_bool()) == Some(true) {
                        if let Some(data) = msg.payload.get("data") {
                            if let Ok(encrypted_data) = serde_json::from_value::<crate::crypto::EncryptedData>(data.clone()) {
                                let decrypt_result = crypto.lock().unwrap().decrypt_message(&encrypted_data);
                                
                                match decrypt_result {
                                    Ok(decrypted_text) => {
                                        let sender = msg.sender_id.as_deref().unwrap_or("Unknown");
                                        println!("\n[←] From {}: {}", sender, decrypted_text);
                                        print!("> ");
                                        io::stdout().flush().ok();

                                        // Save to storage
                                        if let Ok(s) = storage.lock() {
                                            let payload = serde_json::json!({"text": &decrypted_text});
                                            let _ = s.save_message(
                                                &msg.id, "text",
                                                msg.sender_id.as_deref(),
                                                msg.recipient_id.as_deref(),
                                                &payload, msg.timestamp, false,
                                            );
                                        }
                                    }
                                    Err(e) => {
                                        println!("\n[✗] Decryption error: {}", e);
                                        print!("> ");
                                        io::stdout().flush().ok();
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    } else {
        println!("\n[←] Raw: {}", message_str);
        print!("> ");
        io::stdout().flush().ok();
    }
}

/// Check for restricted environments and warn the user
fn check_environment_warnings() {
    let mut warnings = Vec::new();
    
    // Check for GitHub Codespaces
    if std::env::var("CODESPACES").is_ok() || std::env::var("GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN").is_ok() {
        warnings.push("GitHub Codespaces detected");
    }
    
    // Check for common container environments
    if std::path::Path::new("/.dockerenv").exists() {
        warnings.push("Docker container detected");
    }
    
    if std::env::var("KUBERNETES_SERVICE_HOST").is_ok() {
        warnings.push("Kubernetes environment detected");
    }
    
    // Check for cloud shell environments
    if std::env::var("CLOUD_SHELL").is_ok() {
        warnings.push("Cloud Shell detected");
    }
    
    if !warnings.is_empty() {
        println!("╔══════════════════════════════════════════════════════════╗");
        println!("║                    ⚠️  WARNING ⚠️                          ║");
        println!("╠══════════════════════════════════════════════════════════╣");
        println!("║  Running in a restricted environment:                    ║");
        for warning in &warnings {
            println!("║  • {:<52} ║", warning);
        }
        println!("╠══════════════════════════════════════════════════════════╣");
        println!("║  Tor hidden services may NOT be accessible externally!   ║");
        println!("║                                                          ║");
        println!("║  Reason: Container/cloud environments often block        ║");
        println!("║  incoming connections required for hidden services.      ║");
        println!("║                                                          ║");
        println!("║  For full functionality, run on:                         ║");
        println!("║  • Your local machine                                    ║");
        println!("║  • A VPS with direct network access                      ║");
        println!("║  • A server without NAT restrictions                     ║");
        println!("╚══════════════════════════════════════════════════════════╝");
        println!();
    }
}
