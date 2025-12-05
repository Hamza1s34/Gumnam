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
    pkcs1v15::SigningKey,
    pkcs8::{DecodePrivateKey, DecodePublicKey, EncodePrivateKey, EncodePublicKey, LineEnding},
    sha2::Sha256,
    signature::{RandomizedSigner, Verifier, SignatureEncoding},
    Oaep, RsaPrivateKey, RsaPublicKey,
};
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
        })
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

    /// Sign a message with private key (RSA-PSS with SHA-256)
    pub fn sign_message(&self, message: &str) -> Result<String, CryptoError> {
        let signing_key = SigningKey::<Sha256>::new(self.private_key.clone());
        let mut rng = rand::thread_rng();
        let signature = signing_key.sign_with_rng(&mut rng, message.as_bytes());
        Ok(BASE64.encode(signature.to_bytes()))
    }

    /// Verify message signature
    pub fn verify_signature(
        &self,
        message: &str,
        signature: &str,
        sender_public_key_pem: &str,
    ) -> Result<bool, CryptoError> {
        use rsa::pkcs1v15::{Signature, VerifyingKey};

        let sender_public_key = RsaPublicKey::from_public_key_pem(sender_public_key_pem)
            .map_err(|e| CryptoError::Signature(e.to_string()))?;

        let verifying_key = VerifyingKey::<Sha256>::new(sender_public_key);

        let signature_bytes = BASE64
            .decode(signature)
            .map_err(|e| CryptoError::Signature(e.to_string()))?;

        let sig = Signature::try_from(signature_bytes.as_slice())
            .map_err(|e| CryptoError::Signature(e.to_string()))?;

        match verifying_key.verify(message.as_bytes(), &sig) {
            Ok(_) => Ok(true),
            Err(_) => Ok(false),
        }
    }
}

impl Default for CryptoHandler {
    fn default() -> Self {
        Self::new().expect("Failed to initialize CryptoHandler")
    }
}
