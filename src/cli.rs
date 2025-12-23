//! CLI (headless) mode for Tor Messenger
//!
//! Run without GUI - just the Tor service with terminal output

use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::crypto::CryptoHandler;

use crate::peer::PeerManager;
use crate::storage::MessageStorage;
use crate::tor_service::TorService;
use crate::snf::SnFManager;
use crate::message::{MessageType, MessageProtocol};

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
        }
    };

    // Load the Ed25519 identity key from Tor for signing
    println!("[*] Loading onion identity key for signatures...");
    match tor_service.get_onion_secret_key() {
        Ok(key_bytes) => {
            if let Ok(mut c) = crypto.lock() {
                if let Err(e) = c.set_onion_signing_key(&key_bytes) {
                    println!("[!] Warning: Failed to load onion identity key: {}", e);
                } else {
                    println!("[✓] Identity linked to onion address!");
                }
            }
        }
        Err(e) => println!("[!] Warning: Could not load onion identity key: {}", e),
    }

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

    // Fetch offline messages from IPFS on startup
    let our_onion = onion_address.clone();
    let storage_fetch = Arc::clone(&storage);
    let crypto_fetch = Arc::clone(&crypto);
    let _peer_manager_fetch = Arc::clone(&peer_manager);
    
    thread::spawn(move || {
        println!("[*] Checking IPFS for offline messages...");
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        rt.block_on(async {
            match SnFManager::fetch_offline_messages(&our_onion).await {
                Ok(messages) => {
                    if !messages.is_empty() {
                        println!("[✓] Found {} offline messages on IPFS!", messages.len());
                        for pkg in messages {
                            // First Decryption: Decrypt the outer package to get the Message wrapper
                            let crypto_l = crypto_fetch.lock().unwrap();
                            if let Ok(msg_json) = crypto_l.decrypt_message(&pkg.encrypted_message) {
                                    if let Ok(msg) = crate::message::Message::from_json(&msg_json) {
                                        let sender = msg.sender_id.clone().unwrap_or_default();
                                        
                                            // 3. VERIFY Signature (Proof of Identity)
                                            let mut is_verified = false;
                                            if let Ok(c) = crypto_fetch.lock() {
                                                is_verified = MessageProtocol::verify_message(&msg, &c);
                                            }

                                            if !is_verified {
                                                println!("[!] Warning: Could not verify signature for message from {}. It may be faked!", sender);
                                            }

                                        // Second Decryption: Decrypt the inner message text
                                        if msg.msg_type == MessageType::Text && msg.payload.get("encrypted").and_then(|v| v.as_bool()) == Some(true) {
                                        if let Some(data) = msg.payload.get("data") {
                                            if let Ok(encrypted_data) = serde_json::from_value::<crate::crypto::EncryptedData>(data.clone()) {
                                                if let Ok(decrypted_text) = crypto_l.decrypt_message(&encrypted_data) {
                                                    println!("\n[←] Recovered anonymous offline message from {}: {}", sender, decrypted_text);
                                                    // Save to storage
                                                    if let Ok(s) = storage_fetch.lock() {
                                                        let payload = serde_json::json!({"text": &decrypted_text});
                                                        let _ = s.save_message(
                                                            &msg.id, "text",
                                                            Some(&sender),
                                                            Some(&our_onion),
                                                            &payload, msg.timestamp, false,
                                                        );
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        println!("[✓] No offline messages found on IPFS.");
                    }
                }
                Err(e) => println!("[✗] Failed to fetch from IPFS: {}", e),
            }
        });
        print!("> ");
        io::stdout().flush().ok();
    });

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
    println!("  /delete-all                     - Wipe ALL local data & keys");
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
        } else if input.starts_with("/delete-all") {
            print!("[!] Are you sure you want to delete ALL data and keys? (y/N): ");
            io::stdout().flush().unwrap();
            let mut confirm = String::new();
            if io::stdin().read_line(&mut confirm).is_ok() && confirm.trim().to_lowercase() == "y" {
                println!("[*] Wiping all data...");
                
                // Clear database
                if let Ok(s) = storage.lock() {
                    let _ = s.clear_all_data();
                }
                
                // Stop Tor first
                tor_service.stop();
                
                // Delete database
                let _ = std::fs::remove_file(crate::config::db_path());
                
                println!("[✓] All data wiped. Exiting.");
                break;
            } else {
                println!("[*] WIPE CANCELLED.");
            }
        } else if input.starts_with("/add ") {
            let parts: Vec<&str> = input[5..].splitn(2, ' ').collect();
            let addr = parts[0].trim();
            let nickname = parts.get(1).map(|s| s.trim());

            // Check if adding self
            if addr == onion_address {
                println!("[!] That's your own address. Skipping public key storage (onion identity is sufficient).");
                if let Ok(pm) = peer_manager.lock() {
                    match pm.add_peer(addr, nickname, None) {
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
                        
                        // Send initial handshake (is_response = false)
                        let mut handshake = MessageProtocol::create_handshake_message(&onion_address, false);
                        
                        // Sign the handshake
                        if let Ok(c) = crypto.lock() {
                            let _ = MessageProtocol::sign_message(&mut handshake, &c);
                        }

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
            let stripped = input[6..].trim_start();
            let parts: Vec<&str> = stripped.splitn(2, ' ').collect();
            if parts.len() < 2 {
                println!("[!] Usage: /send <onion_address> <message>");
                continue;
            }
            
            let recipient = parts[0].trim();
            let message = parts[1].trim();

            if true { // We always have the recipient's onion address
                let encrypt_result = crypto.lock().unwrap().encrypt_message(message, recipient);
                
                match encrypt_result {
                    Ok(encrypted_data) => {
                        let mut msg = MessageProtocol::wrap_encrypted_message(
                            &encrypted_data,
                            &onion_address,
                            recipient,
                        );

                        // 3. SIGN the message (Proof of Identity)
                        if let Ok(c) = crypto.lock() {
                            let _ = MessageProtocol::sign_message(&mut msg, &c);
                        }

                        if let Ok(json) = msg.to_json() {
                            let tor = Arc::clone(&tor_service);
                            let peer = recipient.to_string();
                            let msg_text = message.to_string();
                            let storage_c = Arc::clone(&storage);
                            let msg_id = msg.id.clone();
                            let timestamp = msg.timestamp;
                            let sender = onion_address.clone();
                            let crypto_send = Arc::clone(&crypto);

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
                                    Err(e) => {
                                        println!("[✗] Peer offline, uploading to IPFS... ({})", e);
                                        // Fallback to IPFS
                                        let crypto_ipfs = Arc::clone(&crypto_send);
                                        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
                                        rt.block_on(async {
                                            let crypto_snf = crypto_ipfs.lock().unwrap();
                                             match SnFManager::upload_and_announce(
                                                 &peer, &sender, &encrypted_data, &crypto_snf
                                             ).await {
                                                Ok(cid) => println!("[✓] Message pinned & announced to DHT. CID: {}", cid),
                                                Err(e) => println!("[✗] IPFS backup failed: {}", e),
                                            }
                                        });
                                    }
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

    // DEBUG: Print raw message received
    println!("\n[DEBUG] Raw message received (len={}): {:?}", message_str.len(), &message_str[..std::cmp::min(200, message_str.len())]);

    // STRICT: Must be valid JSON
    let msg_data = match serde_json::from_str::<serde_json::Value>(message_str) {
        Ok(data) => data,
        Err(e) => {
            // Silently ignore non-JSON messages (like PING/OK)
            let trimmed = message_str.trim();
            if trimmed != "PING" && trimmed != "OK" && !trimmed.is_empty() {
                println!("\n[⚠] Rejected non-protocol message (not JSON): {}", e);
                println!("[DEBUG] Message bytes: {:?}", message_str.as_bytes());
                print!("> ");
                io::stdout().flush().ok();
            }
            return;
        }
    };

    // Check if it's a web message
    if msg_data.get("type").and_then(|v| v.as_str()) == Some("web_message") {
        let sender = msg_data.get("sender").and_then(|v| v.as_str()).unwrap_or("Anonymous");
        let text = msg_data.get("text").and_then(|v| v.as_str()).unwrap_or("");
        println!("\n[🌐 WEB] From '{}': {}", sender, text);
        print!("> ");
        io::stdout().flush().ok();
        return;
    }

    // STRICT: Must be a valid protocol message
    let msg = match ProtocolMessage::from_json(message_str) {
        Ok(m) => m,
        Err(_) => {
            println!("\n[⚠] Rejected invalid protocol message format");
            print!("> ");
            io::stdout().flush().ok();
            return;
        }
    };

    // STRICT: Must have sender_id
    if msg.sender_id.is_none() {
        println!("\n[⚠] Rejected message without sender_id");
        print!("> ");
        io::stdout().flush().ok();
        return;
    }

    match msg.msg_type {
        MessageType::Handshake => {
            let sender_id = msg.sender_id.as_ref().unwrap();
            
            // Public key is now optional/irrelevant for ECIES if you have the onion address
            let _public_key = msg.payload.get("public_key").and_then(|v| v.as_str());
            
            let is_response = msg.payload.get("is_response")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            
            // Save/Update the peer status
            if let Ok(mut pm) = peer_manager.lock() {
                let _ = pm.add_peer(sender_id, None, _public_key);
                pm.mark_peer_online(sender_id, None);
            }
            
            if is_response {
                println!("\n[✓] Response handshake from: {} (key saved) - exchange complete!", sender_id);
            } else {
                println!("\n[✓] Handshake from: {} (key saved)", sender_id);
                
                // Send response handshake
                let mut response_handshake = MessageProtocol::create_handshake_message(our_onion_address, true);
                
                // Sign the handshake
                if let Ok(c) = crypto.lock() {
                    let _ = MessageProtocol::sign_message(&mut response_handshake, &c);
                }

                if let Ok(json) = response_handshake.to_json() {
                    let tor = Arc::clone(tor_service);
                    let peer = sender_id.clone();
                    thread::spawn(move || {
                        println!("[*] Sending response handshake to {}...", peer);
                        match tor.send_message(&peer, &json) {
                            Ok(_) => println!("[✓] Response handshake sent to {}", peer),
                            Err(e) => println!("[✗] Response handshake failed: {}", e),
                        }
                        print!("> ");
                        io::stdout().flush().ok();
                    });
                }
            }
            
            print!("> ");
            io::stdout().flush().ok();
        }
        MessageType::Text | MessageType::Encrypted => {
            let sender = msg.sender_id.as_ref().unwrap();
            
            // 3. VERIFY Signature (Proof of Identity)
            let mut is_verified = false;
            if let Ok(c) = crypto.lock() {
                is_verified = MessageProtocol::verify_message(&msg, &c);
            }

            if !is_verified {
                println!("\n[!] Warning: Could not verify signature for message from {}. It may be faked!", sender);
            }

            // STRICT: Text messages MUST be encrypted
            if msg.payload.get("encrypted").and_then(|v| v.as_bool()) != Some(true) {
                println!("\n[⚠] Rejected unencrypted text message from {}", sender);
                print!("> ");
                io::stdout().flush().ok();
                return;
            }
            
            // STRICT: Must have data field
            let data = match msg.payload.get("data") {
                Some(d) => d,
                None => {
                    println!("\n[⚠] Rejected encrypted message without data from {}", sender);
                    print!("> ");
                    io::stdout().flush().ok();
                    return;
                }
            };
            
            // STRICT: Must be valid EncryptedData structure
            let encrypted_data = match serde_json::from_value::<crate::crypto::EncryptedData>(data.clone()) {
                Ok(ed) => ed,
                Err(_) => {
                    println!("\n[⚠] Rejected invalid encrypted data format from {}", sender);
                    print!("> ");
                    io::stdout().flush().ok();
                    return;
                }
            };
            
            // Decrypt the message
            match crypto.lock().unwrap().decrypt_message(&encrypted_data) {
                Ok(decrypted_text) => {
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
                    println!("\n[✗] Decryption error from {}: {}", sender, e);
                    print!("> ");
                    io::stdout().flush().ok();
                }
            }
        }
        _ => {
            // Ignore other message types silently
        }
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
