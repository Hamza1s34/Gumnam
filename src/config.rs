//! Configuration settings for Tor Messaging App
//! 
//! Port of Python config.py

use std::path::PathBuf;
use std::fs;

/// Tor SOCKS proxy port
pub const TOR_SOCKS_PORT: u16 = 9350;

/// Tor control port
pub const TOR_CONTROL_PORT: u16 = 9351;

/// Internal port for hidden service
pub const HIDDEN_SERVICE_PORT: u16 = 8080;

/// External port (what users connect to via Tor)
pub const HIDDEN_SERVICE_VIRTUAL_PORT: u16 = 80;

// KEY_SIZE removed (RSA specific)

/// Connection timeout in seconds
pub const CONNECTION_TIMEOUT: u64 = 30;

/// Maximum message size (10MB)
pub const MESSAGE_MAX_SIZE: usize = 10 * 1024 * 1024;

/// Get the base directory for app data (~/.tor_messenger)
pub fn base_dir() -> PathBuf {
    let home = dirs::home_dir().expect("Could not find home directory");
    let base = home.join(".tor_messenger");
    fs::create_dir_all(&base).expect("Could not create base directory");
    base
}

/// Get the Tor data directory
pub fn tor_data_dir() -> PathBuf {
    let dir = base_dir().join("tor_data");
    fs::create_dir_all(&dir).expect("Could not create Tor data directory");
    dir
}

/// Get the hidden service directory
pub fn hidden_service_dir() -> PathBuf {
    let dir = tor_data_dir().join("hidden_service");
    fs::create_dir_all(&dir).expect("Could not create hidden service directory");
    dir
}

/// Get the key directory
pub fn key_dir() -> PathBuf {
    let dir = base_dir().join("keys");
    fs::create_dir_all(&dir).expect("Could not create key directory");
    dir
}

// RSA key path functions removed

/// Get path to SQLite database
pub fn db_path() -> PathBuf {
    base_dir().join("messages.db")
}

/// Get path to log file
pub fn log_file() -> PathBuf {
    base_dir().join("app.log")
}

/// Get the templates directory (relative to executable or project)
pub fn templates_dir() -> PathBuf {
    // Try relative to executable first (MacOS folder)
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let templates = exe_dir.join("templates");
            if templates.exists() {
                return templates;
            }
            // Try Resources folder (macOS app bundle)
            if let Some(contents_dir) = exe_dir.parent() {
                let resources_templates = contents_dir.join("Resources").join("templates");
                if resources_templates.exists() {
                    return resources_templates;
                }
            }
        }
    }
    
    // Fall back to current directory
    PathBuf::from("templates")
}
