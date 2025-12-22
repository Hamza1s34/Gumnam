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
        recipient_public_key_pem: &str,
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
        let outer_encrypted = crypto.encrypt_message(&msg_json, recipient_public_key_pem)
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
            .with_behaviour(|key| {
                let store = MemoryStore::new(key.public().to_peer_id());
                kad::Behaviour::new(key.public().to_peer_id(), store)
            })?
            .build();

        // Listen on random port (transient)
        swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;

        // Add public bootstrap nodes
        let bootstrap_nodes = [
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnoo2uR3uSpx6RHCcXpPvcWKBueu7esYp8v7p8AztZ6S",
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCUuYJSTwtPRYmSrtf84kzsgXafR6x8vsq9y6pEycT4K",
        ];

        for addr in bootstrap_nodes {
            let multi_addr: Multiaddr = addr.parse()?;
            if let Some(peer_id) = multi_addr.iter().find_map(|p| match p {
                libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
                _ => None,
            }) {
                swarm.behaviour_mut().add_address(&peer_id, multi_addr);
            }
        }

        // Start DHT Put
        let key = kad::RecordKey::new(&recipient_hash);
        let record = kad::Record {
            key,
            value: data,
            publisher: None,
            // Extended longevity: 120 days (Note: public nodes may still prune earlier)
            expires: Some(std::time::Instant::now() + Duration::from_secs(120 * 24 * 3600)),
        };

        println!("[SNF] Broadcasting encrypted package to decentralized DHT...");
        swarm.behaviour_mut().put_record(record, kad::Quorum::One)?;

        // Run swarm loop for a bit to ensure propagation
        // Use a longer timeout (40s) for better DHT reliability
        let timeout = tokio::time::sleep(Duration::from_secs(40));
        tokio::pin!(timeout);

        loop {
            tokio::select! {
                event = swarm.select_next_some() => {
                    if let libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                        result: kad::QueryResult::PutRecord(Ok(_)), .. 
                    }) = event {
                        println!("[✓] Message successfully pinned to decentralized DHT network.");
                        return Ok("DHT-RECORD".to_string());
                    }
                }
                _ = &mut timeout => {
                    println!("[!] DHT broadcast timed out, but message may still be propagating.");
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
            .with_behaviour(|key| {
                let store = MemoryStore::new(key.public().to_peer_id());
                kad::Behaviour::new(key.public().to_peer_id(), store)
            })?
            .build();

        // Add public bootstrap nodes
        let bootstrap_nodes = [
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnoo2uR3uSpx6RHCcXpPvcWKBueu7esYp8v7p8AztZ6S",
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCUuYJSTwtPRYmSrtf84kzsgXafR6x8vsq9y6pEycT4K",
        ];
        for addr in bootstrap_nodes {
            let multi_addr: Multiaddr = addr.parse()?;
            if let Some(peer_id) = multi_addr.iter().find_map(|p| match p {
                libp2p::multiaddr::Protocol::P2p(peer_id) => Some(peer_id),
                _ => None,
            }) {
                swarm.behaviour_mut().add_address(&peer_id, multi_addr);
            }
        }

        let key = kad::RecordKey::new(&our_hash);
        swarm.behaviour_mut().get_record(key);

        let mut packages = Vec::new();
        let timeout = tokio::time::sleep(Duration::from_secs(40));
        tokio::pin!(timeout);

        loop {
            tokio::select! {
                event = swarm.select_next_some() => {
                    if let libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                        result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FoundRecord(ref record))), .. 
                    }) = event {
                        if let Ok(pkg) = serde_json::from_slice::<IpfsPackage>(&record.record.value) {
                            packages.push(pkg);
                        }
                    }
                    // Stop if we got a finished query
                    if let libp2p::swarm::SwarmEvent::Behaviour(KadEvent::OutboundQueryProgressed { 
                        result: kad::QueryResult::GetRecord(Ok(kad::GetRecordOk::FinishedWithNoAdditionalRecord { .. })), .. 
                    }) = event {
                        break;
                    }
                }
                _ = &mut timeout => break,
            }
        }

        Ok(packages)
    }
}
