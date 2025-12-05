//! Tor Serverless Messenger - Rust Implementation
//!
//! A peer-to-peer messaging application using Tor hidden services
//! for anonymous, end-to-end encrypted communication.

use tor_messenger::cli;

fn main() {
    // Initialize logger
    env_logger::init();

    // Run CLI mode
    cli::run_cli();
}
