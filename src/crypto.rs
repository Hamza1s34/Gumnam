//! Cryptographic operations for end-to-end encryption
//!
//! Replaced RSA with Ed25519-X25519 ECIES
//! Uses ChaCha20-Poly1305 for symmetric encryption

use chacha20poly1305::{
    aead::{Aead, KeyInit, OsRng},
    ChaCha20Poly1305, Nonce,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use rand::RngCore;
use ed25519_dalek::{SigningKey, VerifyingKey, Signature, Verifier};
use ed25519_dalek::hazmat::{ExpandedSecretKey, raw_sign};
use x25519_dalek::{StaticSecret, PublicKey as XPublicKey};
use curve25519_dalek::edwards::CompressedEdwardsY;
use curve25519_dalek::scalar::Scalar;
use curve25519_dalek::constants::ED25519_BASEPOINT_TABLE;
use hkdf::Hkdf;
use sha2::{Sha256, Sha512, Digest};
use serde::{Deserialize, Serialize};
use thiserror::Error;

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

/// Encrypted message data structure (ECIES)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncryptedData {
    pub encrypted_message: String,    // Base64 encoded ciphertext + tag
    pub ephemeral_public_key: String, // Base64 encoded X25519 public key
    pub nonce: String,                // Base64 encoded nonce
}

/// Handles encryption, decryption, and key management
pub struct CryptoHandler {
    onion_signing_key: Option<SigningKey>,
    /// Raw expanded secret key from Tor: first 32 bytes = clamped scalar, last 32 = hash right-half
    raw_tor_expanded_key: Option<[u8; 64]>,
    /// Verifying key derived from Tor's clamped scalar (scalar * G)
    tor_verifying_key: Option<VerifyingKey>,
}

impl CryptoHandler {
    /// Create a new CryptoHandler
    pub fn new() -> Result<Self, CryptoError> {
        Ok(Self {
            onion_signing_key: None,
            raw_tor_expanded_key: None,
            tor_verifying_key: None,
        })
    }

    /// Set the onion signing key (Ed25519) loaded from Tor's expanded key file.
    /// Tor's hs_ed25519_secret_key is 64 bytes: 32-byte clamped scalar `a` + 32-byte SHA512 right-half.
    pub fn set_onion_signing_key(&mut self, key_bytes: &[u8]) -> Result<(), CryptoError> {
        if key_bytes.len() != 64 {
            return Err(CryptoError::Signature("Invalid Tor Ed25519 expanded key length (expected 64)".to_string()));
        }
        
        // Store the raw expanded key
        let mut raw_key = [0u8; 64];
        raw_key.copy_from_slice(key_bytes);
        self.raw_tor_expanded_key = Some(raw_key);

        // Compute the correct VerifyingKey from Tor's clamped scalar:
        // PublicKey = scalar * G (Ed25519 base point)
        let mut scalar_bytes = [0u8; 32];
        scalar_bytes.copy_from_slice(&key_bytes[0..32]);
        let scalar = Scalar::from_bytes_mod_order(scalar_bytes);
        let public_point = &scalar * ED25519_BASEPOINT_TABLE;
        let public_key_bytes = public_point.compress().to_bytes();
        
        self.tor_verifying_key = Some(
            VerifyingKey::from_bytes(&public_key_bytes)
                .map_err(|e| CryptoError::Signature(format!("Invalid public key: {}", e)))?
        );
        
        // Also store a placeholder SigningKey (not used for actual signing)
        let mut seed_bytes = [0u8; 32];
        seed_bytes.copy_from_slice(&key_bytes[0..32]);
        self.onion_signing_key = Some(SigningKey::from_bytes(&seed_bytes));
        
        Ok(())
    }
    
    /// Get the raw clamped scalar from Tor's expanded key for X25519
    fn get_x25519_secret_from_tor_key(&self) -> Result<[u8; 32], CryptoError> {
        let raw_key = self.raw_tor_expanded_key.as_ref()
            .ok_or_else(|| CryptoError::Decryption("Tor key not loaded".to_string()))?;
        
        // The first 32 bytes of Tor's expanded key is the clamped scalar `a`.
        // This is ALREADY properly clamped by Tor, so use it directly.
        let mut scalar = [0u8; 32];
        scalar.copy_from_slice(&raw_key[0..32]);
        Ok(scalar)
    }

    /// Encrypt a message using ECIES
    pub fn encrypt_message(
        &self,
        message: &str,
        recipient_onion: &str,
    ) -> Result<EncryptedData, CryptoError> {
        let recipient_ed_pk = Self::onion_to_pubkey(recipient_onion)
            .map_err(|e| CryptoError::Encryption(format!("Invalid recipient onion: {}", e)))?;
        let recipient_x_pk = XPublicKey::from(Self::ed25519_pk_to_x25519(&recipient_ed_pk));

        let mut rng = rand::thread_rng();
        let ephemeral_sk = StaticSecret::random_from_rng(&mut rng);
        let ephemeral_pk = XPublicKey::from(&ephemeral_sk);

        let shared_secret = ephemeral_sk.diffie_hellman(&recipient_x_pk);

        let hk = Hkdf::<Sha256>::new(None, shared_secret.as_bytes());
        let mut okm = [0u8; 32];
        hk.expand(b"tor-messenger-ecies", &mut okm)
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;

        let cipher = ChaCha20Poly1305::new_from_slice(&okm)
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;
        
        let mut nonce_bytes = [0u8; 12];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);

        let encrypted_message = cipher
            .encrypt(nonce, message.as_bytes())
            .map_err(|e| CryptoError::Encryption(e.to_string()))?;

        Ok(EncryptedData {
            encrypted_message: BASE64.encode(&encrypted_message),
            ephemeral_public_key: BASE64.encode(ephemeral_pk.as_bytes()),
            nonce: BASE64.encode(&nonce_bytes),
        })
    }

    /// Decrypt a message using ECIES
    pub fn decrypt_message(&self, encrypted_data: &EncryptedData) -> Result<String, CryptoError> {
        // Use the raw clamped scalar from Tor directly for X25519
        let our_x_sk_bytes = self.get_x25519_secret_from_tor_key()?;
        let our_x_sk = StaticSecret::from(our_x_sk_bytes);

        let ephem_pk_bytes = BASE64.decode(&encrypted_data.ephemeral_public_key)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        if ephem_pk_bytes.len() != 32 {
            return Err(CryptoError::Decryption("Invalid ephemeral public key length".to_string()));
        }
        let mut pk_arr = [0u8; 32];
        pk_arr.copy_from_slice(&ephem_pk_bytes);
        let ephem_x_pk = XPublicKey::from(pk_arr);

        let shared_secret = our_x_sk.diffie_hellman(&ephem_x_pk);

        let hk = Hkdf::<Sha256>::new(None, shared_secret.as_bytes());
        let mut okm = [0u8; 32];
        hk.expand(b"tor-messenger-ecies", &mut okm)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        let cipher = ChaCha20Poly1305::new_from_slice(&okm)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        
        let nonce_bytes = BASE64.decode(&encrypted_data.nonce)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;
        let nonce = Nonce::from_slice(&nonce_bytes);

        let ciphertext = BASE64.decode(&encrypted_data.encrypted_message)
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        let decrypted = cipher
            .decrypt(nonce, ciphertext.as_ref())
            .map_err(|e| CryptoError::Decryption(e.to_string()))?;

        String::from_utf8(decrypted).map_err(|e| CryptoError::Decryption(e.to_string()))
    }

    fn ed25519_pk_to_x25519(ed_pk: &VerifyingKey) -> [u8; 32] {
        let compressed = CompressedEdwardsY(ed_pk.to_bytes());
        if let Some(edwards_point) = compressed.decompress() {
            edwards_point.to_montgomery().to_bytes()
        } else {
            [0u8; 32]
        }
    }

    fn ed25519_sk_to_x25519(ed_sk: &SigningKey) -> [u8; 32] {
        let mut hasher = Sha512::new();
        hasher.update(ed_sk.to_bytes());
        let hash = hasher.finalize();
        let mut x_sk = [0u8; 32];
        x_sk.copy_from_slice(&hash[0..32]);
        
        // Clamping (pruning) the secret key for X25519
        x_sk[0]  &= 248;
        x_sk[31] &= 127;
        x_sk[31] |= 64;
        
        x_sk
    }

    /// Sign a message using Tor's raw expanded key via hazmat API
    pub fn sign_with_onion_key(&self, message: &str) -> Result<String, CryptoError> {
        let raw_key = self.raw_tor_expanded_key.as_ref()
            .ok_or_else(|| CryptoError::Signature("Tor key not loaded".to_string()))?;
        
        let expanded_key = ExpandedSecretKey::from_bytes(raw_key);
        
        // Use the correctly derived verifying key (scalar * G)
        let verifying_key = self.tor_verifying_key.as_ref()
            .ok_or_else(|| CryptoError::Signature("Verifying key not computed".to_string()))?;
        
        let signature = raw_sign::<Sha512>(&expanded_key, message.as_bytes(), verifying_key);
        
        Ok(BASE64.encode(signature.to_bytes()))
    }

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

    pub fn onion_to_pubkey(onion: &str) -> anyhow::Result<VerifyingKey> {
        let onion = onion.trim().trim_end_matches(".onion").to_lowercase();
        if onion.len() != 56 {
            return Err(anyhow::anyhow!("Invalid onion address length (must be v3)"));
        }
        let alphabet = base32::Alphabet::RFC4648 { padding: false };
        let decoded = base32::decode(alphabet, &onion)
            .ok_or_else(|| anyhow::anyhow!("Failed to decode base32 onion address"))?;
        if decoded.len() != 35 {
            return Err(anyhow::anyhow!("Invalid decoded onion length"));
        }
        let mut pk_bytes = [0u8; 32];
        pk_bytes.copy_from_slice(&decoded[0..32]);
        if decoded[34] != 0x03 {
            return Err(anyhow::anyhow!("Not a v3 onion address (invalid version byte)"));
        }
        VerifyingKey::from_bytes(&pk_bytes).map_err(|e| anyhow::anyhow!(e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Generate a valid test onion address AND its properly expanded secret key
    fn generate_test_onion() -> (SigningKey, String, [u8; 64]) {
        let mut rng = rand::thread_rng();
        let signing_key = SigningKey::generate(&mut rng);
        let pk = signing_key.verifying_key();
        
        let mut onion_bytes = [0u8; 35];
        onion_bytes[0..32].copy_from_slice(pk.as_bytes());
        onion_bytes[34] = 0x03;
        
        let alphabet = base32::Alphabet::RFC4648 { padding: false };
        let onion = format!("{}.onion", base32::encode(alphabet, &onion_bytes).to_lowercase());
        
        // Create expanded key like Tor does: H(seed) = [clamped_scalar || rh]
        let mut hasher = Sha512::new();
        hasher.update(signing_key.to_bytes());
        let hash = hasher.finalize();
        
        let mut expanded_key = [0u8; 64];
        expanded_key.copy_from_slice(&hash);
        
        // Clamp the scalar (first 32 bytes)
        expanded_key[0] &= 248;
        expanded_key[31] &= 127;
        expanded_key[31] |= 64;
        
        (signing_key, onion, expanded_key)
    }

    #[test]
    fn test_ecies_loop() {
        let mut crypto_sender = CryptoHandler::new().unwrap();
        let mut crypto_recipient = CryptoHandler::new().unwrap();
        
        let (_, _, sender_expanded_key) = generate_test_onion();
        let (_, recipient_onion, recipient_expanded_key) = generate_test_onion();
        
        crypto_sender.set_onion_signing_key(&sender_expanded_key).unwrap();
        crypto_recipient.set_onion_signing_key(&recipient_expanded_key).unwrap();
        
        let message = "Hello, ECIES encryption!";
        let encrypted = crypto_sender.encrypt_message(message, &recipient_onion).unwrap();
        let decrypted = crypto_recipient.decrypt_message(&encrypted).unwrap();
        
        assert_eq!(message, decrypted);
    }

    #[test]
    fn test_signature_verification() {
        let mut crypto = CryptoHandler::new().unwrap();
        let (_, onion, expanded_key) = generate_test_onion();
        
        crypto.set_onion_signing_key(&expanded_key).unwrap();

        let message = "This is a signed message authenticated by onion address";
        let signature_b64 = crypto.sign_with_onion_key(message).unwrap();

        // Verify correctly
        let is_valid = crypto.verify_with_onion_address(message, &signature_b64, &onion).unwrap();
        assert!(is_valid);

        // Verify with wrong message
        let is_valid_wrong_msg = crypto.verify_with_onion_address("modified message", &signature_b64, &onion).unwrap();
        assert!(!is_valid_wrong_msg);

        // Verify with wrong onion
        let (_, wrong_onion, _) = generate_test_onion();
        let is_valid_wrong_onion = crypto.verify_with_onion_address(message, &signature_b64, &wrong_onion).unwrap();
        assert!(!is_valid_wrong_onion);
    }

    #[test]
    fn test_onion_to_pubkey_conversion() {
        let (_, valid_onion, _) = generate_test_onion();
        let res = CryptoHandler::onion_to_pubkey(&valid_onion);
        assert!(res.is_ok());

        let invalid_onion = "too-short.onion";
        let res_invalid = CryptoHandler::onion_to_pubkey(invalid_onion);
        assert!(res_invalid.is_err());
        
        let invalid_version = "v2c76pdyv642lr3mc72ycofvtqsqm477fntit5t2lyw3v6n2p6m4jqya.onion"; // ends in 'a' (0x00? no, 'a' is 0 in base32)
        let res_ver = CryptoHandler::onion_to_pubkey(invalid_version);
        assert!(res_ver.is_err());
    }

    #[test]
    fn test_key_conversion_consistency() {
        let mut rng = rand::thread_rng();
        let ed_sk = SigningKey::generate(&mut rng);
        let ed_pk = ed_sk.verifying_key();
        
        // 1. Convert seed to expanded key like Tor does
        let mut hasher = Sha512::new();
        hasher.update(ed_sk.to_bytes());
        let hash = hasher.finalize();
        let mut expanded_scalar = [0u8; 32];
        expanded_scalar.copy_from_slice(&hash[0..32]);
        expanded_scalar[0] &= 248;
        expanded_scalar[31] &= 127;
        expanded_scalar[31] |= 64;
        
        // Get X25519 public key from this clamped scalar
        let x_sk = StaticSecret::from(expanded_scalar);
        let x_pk_from_sk = XPublicKey::from(&x_sk);
        
        // 2. Convert Ed25519 public key directly to X25519
        let x_pk_from_pk_bytes = CryptoHandler::ed25519_pk_to_x25519(&ed_pk);
        let x_pk_from_pk = XPublicKey::from(x_pk_from_pk_bytes);
        
        // They must be identical for ECIES to work!
        assert_eq!(x_pk_from_sk.as_bytes(), x_pk_from_pk.as_bytes());
    }
}
