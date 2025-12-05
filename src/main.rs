//! Tor Serverless Messenger - Rust Implementation
//!
//! A peer-to-peer messaging application using Tor hidden services
//! for anonymous, end-to-end encrypted communication.

use tor_messenger::cli;
use tor_messenger::gui;

use std::env;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logger
    env_logger::init();

    // Check for CLI mode
    let args: Vec<String> = env::args().collect();
    
    if args.iter().any(|a| a == "--cli" || a == "--headless" || a == "-c") {
        // Run in CLI/headless mode
        cli::run_cli();
        Ok(())
    } else {
        // Run with GUI
        println!("Starting Tor Serverless Messenger...");
        println!("(Use --cli or --headless for terminal-only mode)");
        println!();
        
        use gui::TorMessengerApp;
        use iced::Size;

        iced::application(TorMessengerApp::title, TorMessengerApp::update, TorMessengerApp::view)
            .theme(TorMessengerApp::theme)
            .antialiasing(true)
            .window_size(Size::new(900.0, 700.0))
            .run_with(|| {
                let (mut app, cmd) = TorMessengerApp::new();
                let start_cmd = app.start_tor();
                (app, iced::Task::batch([cmd, start_cmd]))
            })?;
        
        Ok(())
    }
}
