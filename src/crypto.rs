//! Cryptographic operations for end-to-end encryption
//!
//! Port of Python crypto_handler.py
//! Uses RSA for asymmetric encryption and AES-GCM for symmetric encryption

use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use rand::RngCore;
use rsa::{
    pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey, LineEnding},
    sha2::Sha256,
    signature::{SignatureEncoding},
    Oaep, RsaPrivateKey, RsaPublicKey,
};
use ed25519_dalek::{SigningKey, VerifyingKey, Signature, Signer, Verifier};
use serde::{Deserialize, Serialize};
use std::fs;
use thiserror::Error;

use crate::config;

#[derive(Error, Debug)]
pub enum CryptoError {
    #[error("Key generation failed: {0}")]
    KeyGeneration(String),
    #[error("Encryption failed: {0}")]
    Encryption(String),
    #[error("Decryption failed: {0}")]
    Decryption(String),
    #[error("Key loading failed: {0}")]
    KeyLoading(String),
    #[error("Signature error: {0}")]
    Signature(String),
}

/// Encrypted message data structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedData {
    pub encrypted_message: String, // Base64 encoded
    pub encrypted_key: String,     // Base64 encoded
    pub nonce: String,             // Base64 encoded (for AES-GCM)
}

/// Handles encryption, decryption, and key management
pub struct CryptoHandler {
    private_key: RsaPrivateKey,
    public_key: RsaPublicKey,
    onion_signing_key: Option<SigningKey>,
}

impl CryptoHandler {
    /// Create a new CryptoHandler, loading existing keys or generating new ones
    pub fn new() -> Result<Self, CryptoError> {
        let private_key_path = config::private_key_file();
        let public_key_path = config::public_key_file();

        if private_key_path.exists() && public_key_path.exists() {
            Self::load_keys()
        } else {
            Self::generate_keys()
        }
    }

    /// Generate new RSA key pair
    fn generate_keys() -> Result<Self, CryptoError> {
        println!("Generating new RSA key pair...");

        let mut rng = rand::thread_rng();
        let private_key = RsaPrivateKey::new(&mut rng, config::KEY_SIZE as usize)
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))?;
        let public_key = RsaPublicKey::from(&private_key);

        // Save keys to disk
        let private_pem = private_key
            .to_pkcs8_pem(LineEnding::LF)
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))?;
        fs::write(config::private_key_file(), private_pem.as_bytes())
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))?;

        let public_pem = public_key
            .to_public_key_pem(LineEnding::LF)
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))?;
        fs::write(config::public_key_file(), public_pem.as_bytes())
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))?;

        println!("Keys saved to {:?}", config::key_dir());

        Ok(Self {
            private_key,
            public_key,
            onion_signing_key: None,
        })
    }

    /// Load existing keys from disk
    fn load_keys() -> Result<Self, CryptoError> {
        let private_pem = fs::read_to_string(config::private_key_file())
            .map_err(|e| CryptoError::KeyLoading(e.to_string()))?;
        let private_key = RsaPrivateKey::from_pkcs8_pem(&private_pem)
            .map_err(|e| CryptoError::KeyLoading(e.to_string()))?;

        let public_pem = fs::read_to_string(config::public_key_file())
            .map_err(|e| CryptoError::KeyLoading(e.to_string()))?;
        let public_key = RsaPublicKey::from_public_key_pem(&public_pem)
            .map_err(|e| CryptoError::KeyLoading(e.to_string()))?;

        Ok(Self {
            private_key,
            public_key,
            onion_signing_key: None,
        })
    }

    /// Set the onion signing key (Ed25519) loaded from Tor
    pub fn set_onion_signing_key(&mut self, key_bytes: &[u8]) -> Result<(), CryptoError> {
        if key_bytes.len() != 64 {
            return Err(CryptoError::Signature("Invalid Ed25519 secret key length".to_string()));
        }
        let mut bytes = [0u8; 32];
        bytes.copy_from_slice(&key_bytes[0..32]);
        let signing_key = SigningKey::from_bytes(&bytes);
        self.onion_signing_key = Some(signing_key);
        Ok(())
    }

    /// Get public key in PEM format for sharing
    pub fn get_public_key_pem(&self) -> Result<String, CryptoError> {
        self.public_key
            .to_public_key_pem(LineEnding::LF)
            .map_err(|e| CryptoError::KeyGeneration(e.to_string()))
    }

    /// Encrypt a message using hybrid encryption:
    /// 1. Generate random AES-256 key
    /// 2. Encrypt message with AES-GCM
    /// 3. Encrypt AES key with recipient's RSA public key
    pub fn encrypt_message(
        &self,
        message: &str,
        recipient_public_key_pem: &str,
    ) -> Result<EncryptedData, CryptoError> {
        // Load recipient's public key
        let recipient_public_key = RsaPublicKey::from_public_key_pem(recipient_public_key_pem)
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;

        // Generate random 256-bit AES key
        let mut aes_key = [0u8; 32];
        OsRng.fill_bytes(&mut aes_key);

        // Generate random 96-bit nonce for AES-GCM
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        // Encrypt message with AES-GCM
        let cipher = Aes256Gcm::new_from_slice(&aes_key)
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;
        let encrypted_message = cipher
            .encrypt(nonce, message.as_bytes())
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;

        // Encrypt AES key with recipient's RSA public key using OAEP
        let padding = Oaep::new::<Sha256>();
        let mut rng = rand::thread_rng();
        let encrypted_key = recipient_public_key
            .encrypt(&mut rng, padding, &aes_key)
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;

        Ok(EncryptedData {
            encrypted_message: BASE64.encode(&encrypted_message),
            encrypted_key: BASE64.encode(&encrypted_key),
            nonce: BASE64.encode(&nonce_bytes),
        })
    }

    /// Decrypt a message using hybrid encryption:
    /// 1. Decrypt AES key with private RSA key
    /// 2. Decrypt message with AES-GCM
    pub fn decrypt_message(&self, encrypted_data: &EncryptedData) -> Result<String, CryptoError> {
        // Decode from base64
        let encrypted_message = BASE64
            .decode(&encrypted_data.encrypted_message)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        let encrypted_key = BASE64
            .decode(&encrypted_data.encrypted_key)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        let nonce_bytes = BASE64
            .decode(&encrypted_data.nonce)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        // Decrypt AES key with private RSA key
        let padding = Oaep::new::<Sha256>();
        let aes_key = self
            .private_key
            .decrypt(padding, &encrypted_key)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        // Decrypt message with AES-GCM
        let cipher = Aes256Gcm::new_from_slice(&aes_key)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        let nonce = Nonce::from_slice(&nonce_bytes);
        let decrypted = cipher
            .decrypt(nonce, encrypted_message.as_ref())
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        String::from_utf8(decrypted).map_err(|e| CryptoError::Decryption(e.to_string()))
    }

    /// Sign a message using the Ed25519 key (Identity Linked to Onion)
    pub fn sign_with_onion_key(&self, message: &str) -> Result<String, CryptoError> {
        let key = self.onion_signing_key.as_ref()
            .ok_or_else(|| CryptoError::Signature("Onion signing key not loaded".to_string()))?;
        
        let signature = key.sign(message.as_bytes());
        Ok(BASE64.encode(signature.to_bytes()))
    }

    /// Verify signature using a .onion address (decoding it to Ed25519 public key)
    pub fn verify_with_onion_address(
        &self,
        message: &str,
        signature_b64: &str,
        onion_address: &str,
    ) -> Result<bool, CryptoError> {
        let pub_key = Self::onion_to_pubkey(onion_address)
            .map_err(|e| CryptoError::Signature(e.to_string()))?;
        
        let sig_bytes = BASE64.decode(signature_b64)
            .map_err(|e| CryptoError::Signature(e.to_string()))?;
        
        let signature = Signature::from_slice(&sig_bytes)
            .map_err(|e| CryptoError::Signature(e.to_string()))?;
        
        match pub_key.verify(message.as_bytes(), &signature) {
            Ok(_) => Ok(true),
            Err(_) => Ok(false),
        }
    }

    /// Convert a Tor v3 .onion address back into an Ed25519 public key
    pub fn onion_to_pubkey(onion: &str) -> anyhow::Result<VerifyingKey> {
        // Remove .onion suffix if present
        let onion = onion.trim_end_matches(".onion").to_lowercase();
        
        // V3 onions are 56 chars (Base32)
        if onion.len() != 56 {
            return Err(anyhow::anyhow!("Invalid onion address length (must be v3)"));
        }

        // Decode Base32
        let alphabet = base32::Alphabet::RFC4648 { padding: false };
        let decoded = base32::decode(alphabet, &onion)
            .ok_or_else(|| anyhow::anyhow!("Failed to decode base32 onion address"))?;

        if decoded.len() != 35 {
            return Err(anyhow::anyhow!("Invalid decoded onion length"));
        }

        // The first 32 bytes are the Ed25519 public key
        let mut pk_bytes = [0u8; 32];
        pk_bytes.copy_from_slice(&decoded[0..32]);
        
        // verify version (last byte should be 0x03)
        if decoded[34] != 0x03 {
            return Err(anyhow::anyhow!("Not a v3 onion address (invalid version byte)"));
        }

        VerifyingKey::from_bytes(&pk_bytes).map_err(|e| anyhow::anyhow!(e))
    }
}

impl Default for CryptoHandler {
    fn default() -> Self {
        Self::new().expect("Failed to initialize CryptoHandler")
    }
}
