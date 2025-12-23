# 👻 Gumnam
### *a serverless privacy focused messenger app*

![License](https://img.shields.io/badge/license-MIT-purple.svg?style=for-the-badge)
![Privacy](https://img.shields.io/badge/Privacy-Maximized-critical?style=for-the-badge&logo=tor)
![Status](https://img.shields.io/badge/Status-Beta-blue?style=for-the-badge)

> [!WARNING]  
> **⚠️ Under Development**: Gumnam is currently in **alpha**. It has not yet been audited and should **not** be used for critical privacy needs. Use at your own risk.

---

## 🦄 Uniqueness
Why settle for "secure" when you can be **invisible**? 😶‍🌫️
**Gumnam** isn't just another chat app. It's your digital ghost suit. No servers to hack, no metadata to leak, just pure, unadulterated p2p connection. You don't just "use" Gumnam; you *disappear* into it.

## 🔐 Encryption Scheme
We use state-of-the-art cryptography to ensure your messages stay yours. Period.
*   **Key Exchange**: `X25519` (Diffie-Hellman) for establishing shared secrets.
*   **Encryption**: `ChaCha20Poly1305` (IETF variant) for authenticated encryption.
*   **Signing**: `Ed25519` for digital signatures and identity verification.
*   **Key Derivation**: `HKDF` (SHA-256) for secure key generation.

## 🚀 Efficiency - Fast af ⚡
We don't do bloat.
*   **Serverless Architecture**: No middleman slowing you down.
*   **Direct P2P**: Your messages fly straight to the destination.
*   **Rust Backend**: Powered by the speed and safety of Rust 🦀.
*   **Lightweight UI**: Buttery smooth Flutter interface ✨.

## 🕵️‍♀️ Privacy & Security - Lock it down 🔒
Casual vibes, *serious* security.
*   **Tor Network**: All traffic is routed through Tor hidden services. IP addresses? Never heard of 'em. 🧅
*   **End-to-End Encryption**: Only you and the receiver have the keys. We couldn't read your messages if we wanted to (and we really don't). 🗝️
*   **No Logs, No Trace**: What happens on Gumnam, stays in the void.

## ⚙️ Working Mechanism - How the magic happens 🧙‍♂️
1.  **Identity Generation**: You generate a unique cryptographic identity (Onion address).
2.  **Handshake**: Connect to peers anonymously via the Tor network.
3.  **Secure Tunnel**: Establish a secure, encrypted tunnel.
4.  **Chat**: Send updates, memes, and secrets freely.

## 🏷️ Tags
`#privacy` `#serverless` `#tor` `#rust` `#flutter` `#p2p` `#secure-messaging` `#anonymous` `#gumnam`

---
*Stay hidden. Stay Gumnam.* 👻
