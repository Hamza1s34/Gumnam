use crate::message::MessageProtocol;
use crate::crypto::{CryptoHandler, EncryptedData};
use serde::{Deserialize, Serialize};
use sha2::{Sha256, Digest};
use std::time::Duration;
use futures::StreamExt;
use libp2p::{
    kad::{self, store::MemoryStore, Event as KadEvent},
    noise,
    tcp,
    yamux,
    SwarmBuilder,
    PeerId,
    Multiaddr,
    identity,
};

/// IPFS Package structure for offline storage (Anonymous)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IpfsPackage {
    pub recipient_hash: String,     // SHA256(recipient_onion)
    pub encrypted_message: EncryptedData, // Encrypted(JSON of Message)
    pub timestamp: i64,
}

pub struct SnFManager;

impl SnFManager {
    /// Create a hash of the onion address to use as an IPFS key
    pub fn get_onion_hash(onion: &str) -> String {
        let mut hasher = Sha256::new();
        hasher.update(onion.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    /// Upload to the decentralized network using an embedded DHT node
    pub async fn upload_and_announce(
        recipient_onion: &str,
        sender_onion: &str,
        encrypted_data: &EncryptedData,
        crypto: &CryptoHandler,
    ) -> anyhow::Result<String> {
        let recipient_hash = Self::get_onion_hash(recipient_onion);
        
        // 1. Wrap in message structure
        let mut msg = MessageProtocol::wrap_encrypted_message(encrypted_data, sender_onion, recipient_onion);
        
        // 2. SIGN the message (Proof of Identity)
        MessageProtocol::sign_message(&mut msg, crypto)?;
        
        let msg_json = serde_json::to_string(&msg)?;
        
        // 3. DOUBLE-ENCRYPT for anonymity
        let outer_encrypted = crypto.encrypt_message(&msg_json, recipient_onion)
            .map_err(|e| anyhow::anyhow!("Outer encryption failed: {}", e))?;

        let package = IpfsPackage {
            recipient_hash: recipient_hash.clone(),
            encrypted_message: outer_encrypted,
            timestamp: chrono::Utc::now().timestamp(),
        };

        let data = serde_json::to_vec(&package)?;

        // Check size: DHT records should ideally be small, but we'll allow up to 1MB
        if data.len() > 1024 * 1024 {
            println!("[!] Warning: Message is very large ({} bytes). DHT delivery is highly unreliable above 1MB.", data.len());
        }

        println!("[SNF] Initializing small embedded p2p node for upload...");
        
        // Setup libp2p node
        let local_key = identity::Keypair::generate_ed25519();
        let _local_peer_id = PeerId::from(local_key.public());
        
        let mut swarm = SwarmBuilder::with_existing_identity(local_key)
            .with_tokio()
            .with_tcp(
                tcp::Config::default(),
                noise::Config::new,
                yamux::Config::default,
            )?
            .with_dns()?
            .with_behaviour(|key| {
                let store = MemoryStore::new(key.public().to_peer_id());
                kad::Behaviour::new(key.public().to_peer_id(), store)
            })?
            .build();

        // Listen on random port (transient)
        swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;

        println!("[SNF] Initializing embedded p2p node (PeerId: {})...", swarm.local_peer_id());

        // Standard IPFS/libp2p Bootstrap Nodes
        let bootstrap_nodes = [
            "/ip4/104.131.131.82/tcp/4001/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmZa1sAxajnQjVM8WjWXoMbmPd7NsWhfKsPkErzpm9wGkp",
        ];

        for addr in bootstrap_nodes {
            if let Ok(multi_addr) = addr.parse::<Multiaddr>() {
                // libp2p 0.50+ and modern IPFS use /p2p/ as the canonical protocol name.
                // The parser converts /ipfs/ to /p2p/ automatically if it's at the end.
                if let Some(peer_id) = multi_addr.iter().find_map(|p| match p {
                    libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
                    _ => None,
                }) {
                    swarm.behaviour_mut().add_address(&peer_id, multi_addr);
                }
            }
        }

        // Set to client mode for ephemeral operations
        swarm.behaviour_mut().set_mode(Some(kad::Mode::Client));

        println!("[SNF] Bootstrapping DHT routing table...");
        swarm.behaviour_mut().bootstrap().ok();

        // Start DHT Put
        let key = kad::RecordKey::new(&recipient_hash);
        let record = kad::Record {
            key,
            value: data,
            publisher: None,
            // Extended longevity: 120 days (Note: public nodes may still prune earlier)
            expires: Some(std::time::Instant::now() + Duration::from_secs(120 * 24 * 3600)),
        };

        let mut bootstrap_complete = false;
        let mut put_started = false;
        let mut put_error_shown = false;

        // Increased timeout (120s) for public DHT propagation
        let timeout = tokio::time::sleep(Duration::from_secs(120));
        tokio::pin!(timeout);

        loop {
            tokio::select! {
                event = swarm.select_next_some() => {
                    match event {
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::Bootstrap(Ok(_)), .. 
                        }) => {
                            if !bootstrap_complete {
                                let peer_count = swarm.behaviour_mut().kbuckets().count();
                                if peer_count > 0 {
                                    println!("[SNF] Bootstrap complete. Found {} peers. Ready to put record.", peer_count);
                                } else {
                                    println!("[SNF] Warning: Bootstrap finished with 0 peers. Record may not be reachable.");
                                }
                                bootstrap_complete = true;
                                // Now we can put the record
                                if !put_started {
                                    swarm.behaviour_mut().put_record(record.clone(), kad::Quorum::One)?;
                                    put_started = true;
                                }
                            }
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::PutRecord(Ok(_)), .. 
                        }) => {
                            println!("[✓] Message confirmed as stored on the DHT network.");
                            return Ok("DHT-RECORD".to_string());
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::PutRecord(Err(e)), .. 
                        }) => {
                            if !put_error_shown {
                                println!("[!] DHT Store error: {:?}. Retrying...", e);
                                put_error_shown = true;
                            }
                            swarm.behaviour_mut().put_record(record.clone(), kad::Quorum::One).ok();
                        }
                        libp2p::swarm::SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                            println!("[SNF] Connected to peer: {}", peer_id);
                        }
                        libp2p::swarm::SwarmEvent::IncomingConnectionError { error, .. } => {
                            println!("[SNF] Incoming connection error: {:?}", error);
                        }
                        _ => {}
                    }
                }
                _ = &mut timeout => {
                    if !put_started {
                         println!("[SNF] Bootstrap failed or took too long. Forcing upload attempt...");
                         let _ = swarm.behaviour_mut().put_record(record, kad::Quorum::One);
                         tokio::time::sleep(Duration::from_secs(10)).await;
                    }
                    println!("[!] DHT timeout reached. The network is busy; the message may still propagate eventually.");
                    return Ok("DHT-PROPAGATING".to_string());
                }
            }
        }
    }

    /// Fetch offline messages using embedded node (DHT lookup)
    pub async fn fetch_offline_messages(
        our_onion: &str,
    ) -> anyhow::Result<Vec<IpfsPackage>> {
        let our_hash = Self::get_onion_hash(our_onion);
        println!("[SNF] Checking decentralized DHT for messages addressed to our hash...");

        let local_key = identity::Keypair::generate_ed25519();
        let mut swarm = SwarmBuilder::with_existing_identity(local_key)
            .with_tokio()
            .with_tcp(tcp::Config::default(), noise::Config::new, yamux::Config::default)?
            .with_dns()?
            .with_behaviour(|key| {
                let store = MemoryStore::new(key.public().to_peer_id());
                kad::Behaviour::new(key.public().to_peer_id(), store)
            })?
            .build();

        println!("[SNF] Initializing embedded p2p node (PeerId: {})...", swarm.local_peer_id());

        // Standard IPFS/libp2p Bootstrap Nodes
        let bootstrap_nodes = [
            "/ip4/104.131.131.82/tcp/4001/ipfs/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
            "/dnsaddr/bootstrap.libp2p.io/ipfs/QmZa1sAxajnQjVM8WjWXoMbmPd7NsWhfKsPkErzpm9wGkp",
        ];
        for addr in bootstrap_nodes {
            if let Ok(multi_addr) = addr.parse::<Multiaddr>() {
                if let Some(peer_id) = multi_addr.iter().find_map(|p| match p {
                    libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
                    _ => None,
                }) {
                    swarm.behaviour_mut().add_address(&peer_id, multi_addr);
                }
            }
        }

        // Set to client mode
        swarm.behaviour_mut().set_mode(Some(kad::Mode::Client));
        
        println!("[SNF] Bootstrapping DHT routing table...");
        swarm.behaviour_mut().bootstrap().ok();

        let key = kad::RecordKey::new(&our_hash);
        let mut get_started = false;

        let mut packages = Vec::new();
        // Increased timeout (90s) for fetching from public DHT
        let timeout = tokio::time::sleep(Duration::from_secs(90));
        tokio::pin!(timeout);

        loop {
            tokio::select! {
                event = swarm.select_next_some() => {
                    match event {
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::Bootstrap(Ok(_)), .. 
                        }) => {
                            if !get_started {
                                let peer_count = swarm.behaviour_mut().kbuckets().count();
                                if peer_count > 0 {
                                    println!("[SNF] Bootstrap complete. Found {} peers. Fetching records...", peer_count);
                                } else {
                                    println!("[SNF] Warning: Bootstrap finished with 0 peers. Messages might not be found.");
                                }
                                swarm.behaviour_mut().get_record(key.clone());
                                get_started = true;
                            }
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(ref record))), .. 
                        }) => {
                            println!("[✓] Found record on the DHT network!");
                            if let Ok(pkg) = serde_json::from_slice::<IpfsPackage>(&record.record.value) {
                                packages.push(pkg);
                            }
                        }
                        libp2p::swarm::SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                            println!("[SNF] Connected to peer: {}", peer_id);
                        }
                        libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                            result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FinishedWithNoAdditionalRecord { .. })), .. 
                        }) => {
                            break;
                        }
                        _ => {}
                    }
                }
                _ = &mut timeout => {
                    if !get_started {
                        // Force get if bootstrap taking too long
                        println!("[SNF] Bootstrap taking too long, forcing fetch...");
                        swarm.behaviour_mut().get_record(key.clone());
                        tokio::time::sleep(Duration::from_secs(5)).await;
                    }
                    break;
                }
            }
        }

        Ok(packages)
    }
}
