//! Tor service integration for hidden service management with embedded Tor
//!
//! Port of Python tor_service.py

use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use thiserror::Error;

use crate::config;

/// Get the path to the bundled Tor binary
fn get_bundled_tor_path() -> Option<PathBuf> {
    // Try relative to executable first
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            // Check in bin/tor directory relative to executable
            let tor_path = exe_dir.join("bin").join("tor").join("tor");
            if tor_path.exists() {
                return Some(tor_path);
            }
            
            // Check for macOS app bundle structure (Contents/MacOS -> Contents/Resources/bin/tor)
            if let Some(contents_dir) = exe_dir.parent() {
                let resources_tor = contents_dir.join("Resources").join("bin").join("tor").join("tor");
                if resources_tor.exists() {
                    return Some(resources_tor);
                }
            }
            
            // Check one level up (for when running from target/debug)
            if let Some(parent) = exe_dir.parent() {
                if let Some(parent2) = parent.parent() {
                    let tor_path = parent2.join("bin").join("tor").join("tor");
                    if tor_path.exists() {
                        return Some(tor_path);
                    }
                }
            }
        }
    }
    
    // Try relative to current working directory
    let cwd_tor = PathBuf::from("bin/tor/tor");
    if cwd_tor.exists() {
        return Some(cwd_tor.canonicalize().unwrap_or(cwd_tor));
    }
    
    // Try from project root (common development scenario)
    if let Ok(cwd) = std::env::current_dir() {
        let tor_path = cwd.join("bin").join("tor").join("tor");
        if tor_path.exists() {
            return Some(tor_path);
        }
    }
    
    None
}

/// Get the path to the Tor binary (bundled or system)
fn get_tor_binary_path() -> PathBuf {
    // On macOS, prefer system Tor since bundled binaries would be Linux binaries
    #[cfg(target_os = "macos")]
    {
        // Check common macOS Tor installation locations
        let macos_tor_paths = [
            "/usr/local/bin/tor",
            "/opt/homebrew/bin/tor",
            "/usr/local/Cellar/tor/0.4.8.21/bin/tor",
            "/opt/local/bin/tor",  // MacPorts
        ];
        
        for path in macos_tor_paths {
            let tor_path = PathBuf::from(path);
            if tor_path.exists() {
                println!("Using system Tor on macOS: {:?}", tor_path);
                return tor_path;
            }
        }
        
        // Try 'which tor' as fallback
        if let Ok(output) = std::process::Command::new("which").arg("tor").output() {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    println!("Using system Tor from PATH: {}", path);
                    return PathBuf::from(path);
                }
            }
        }
        
        println!("Warning: No system Tor found on macOS. Please install with: brew install tor");
        return PathBuf::from("tor");
    }
    
    // On Linux, try bundled Tor first
    #[cfg(not(target_os = "macos"))]
    {
        if let Some(bundled) = get_bundled_tor_path() {
            println!("Using bundled Tor binary: {:?}", bundled);
            return bundled;
        }
        
        // Fall back to system Tor on Linux
        println!("Bundled Tor not found, trying system Tor...");
        PathBuf::from("tor")
    }
}

/// Get the library path for bundled Tor
fn get_tor_lib_path() -> Option<PathBuf> {
    if let Some(tor_path) = get_bundled_tor_path() {
        if let Some(tor_dir) = tor_path.parent() {
            return Some(tor_dir.to_path_buf());
        }
    }
    None
}

/// Set up environment for Tor process with proper library paths
fn setup_tor_environment(cmd: &mut Command) {
    if let Some(lib_path) = get_tor_lib_path() {
        let lib_path_str = lib_path.to_string_lossy().to_string();
        
        // Set LD_LIBRARY_PATH for Linux
        let existing_ld_path = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
        let new_ld_path = if existing_ld_path.is_empty() {
            lib_path_str.clone()
        } else {
            format!("{}:{}", lib_path_str, existing_ld_path)
        };
        cmd.env("LD_LIBRARY_PATH", new_ld_path);
        
        // Set DYLD_LIBRARY_PATH for macOS
        #[cfg(target_os = "macos")]
        {
            let existing_dyld_path = std::env::var("DYLD_LIBRARY_PATH").unwrap_or_default();
            let new_dyld_path = if existing_dyld_path.is_empty() {
                lib_path_str.clone()
            } else {
                format!("{}:{}", lib_path_str, existing_dyld_path)
            };
            cmd.env("DYLD_LIBRARY_PATH", new_dyld_path);
            
            // Also set DYLD_FALLBACK_LIBRARY_PATH as a fallback
            let existing_fallback = std::env::var("DYLD_FALLBACK_LIBRARY_PATH").unwrap_or_default();
            let new_fallback = if existing_fallback.is_empty() {
                lib_path_str
            } else {
                format!("{}:{}", lib_path_str, existing_fallback)
            };
            cmd.env("DYLD_FALLBACK_LIBRARY_PATH", new_fallback);
        }
    }
}

#[derive(Error, Debug)]
pub enum TorError {
    #[error("Failed to start Tor: {0}")]
    StartFailed(String),
    #[error("Connection error: {0}")]
    Connection(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

/// Bootstrap progress callback type
pub type BootstrapCallback = Box<dyn Fn(u32, &str) + Send + Sync>;

/// Message handler callback type
pub type MessageHandler = Box<dyn Fn(String) + Send + Sync>;

/// Web message received from browser
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebMessage {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub sender: String,
    pub text: String,
    pub timestamp: String,
}

/// Manages Tor hidden service for peer-to-peer messaging with embedded Tor
pub struct TorService {
    pub onion_address: Arc<Mutex<Option<String>>>,
    is_running: Arc<AtomicBool>,
    tor_process: Arc<Mutex<Option<Child>>>,
    message_handler: Arc<Mutex<Option<MessageHandler>>>,
    bootstrap_callback: Arc<Mutex<Option<BootstrapCallback>>>,
    port: u16,
    templates_dir: PathBuf,
}

impl TorService {
    /// Create a new TorService
    pub fn new(message_handler: Option<MessageHandler>) -> Self {
        Self {
            onion_address: Arc::new(Mutex::new(None)),
            is_running: Arc::new(AtomicBool::new(false)),
            tor_process: Arc::new(Mutex::new(None)),
            message_handler: Arc::new(Mutex::new(message_handler)),
            bootstrap_callback: Arc::new(Mutex::new(None)),
            port: config::HIDDEN_SERVICE_PORT,
            templates_dir: config::templates_dir(),
        }
    }

    /// Set bootstrap callback for progress updates
    pub fn set_bootstrap_callback(&self, callback: BootstrapCallback) {
        let mut cb = self.bootstrap_callback.lock().unwrap();
        *cb = Some(callback);
    }

    /// Set message handler
    pub fn set_message_handler(&self, handler: MessageHandler) {
        let mut mh = self.message_handler.lock().unwrap();
        *mh = Some(handler);
    }

    /// Kill any existing Tor processes that might be using our data directory
    pub fn kill_existing_tor_processes() {
        let data_dir = config::tor_data_dir();
        let data_dir_str = data_dir.to_string_lossy();

        // Try to kill processes using our data directory
        if let Ok(output) = Command::new("pgrep")
            .args(["-f", &format!("tor.*{}", data_dir_str)])
            .output()
        {
            let pids = String::from_utf8_lossy(&output.stdout);
            for pid in pids.lines() {
                if !pid.is_empty() {
                    if let Ok(pid_num) = pid.parse::<i32>() {
                        let _ = Command::new("kill")
                            .args(["-TERM", &pid_num.to_string()])
                            .output();
                        println!("Killed existing Tor process (PID: {})", pid);
                    }
                }
            }
        }

        // Wait for processes to terminate
        thread::sleep(Duration::from_secs(2));

        // Remove lock file if exists
        let lock_file = config::tor_data_dir().join("lock");
        if lock_file.exists() {
            if fs::remove_file(&lock_file).is_ok() {
                println!("Removed stale lock file");
            }
        }
    }

    /// Start the embedded Tor process and hidden service
    pub fn start(&self) -> Result<bool, TorError> {
        // Kill any existing Tor processes first
        Self::kill_existing_tor_processes();

        // Create directories with proper permissions
        let tor_data_dir = config::tor_data_dir();
        let hidden_service_dir = config::hidden_service_dir();
        fs::create_dir_all(&tor_data_dir)?;
        fs::create_dir_all(&hidden_service_dir)?;

        // Set proper permissions (Tor requires 700)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&tor_data_dir, fs::Permissions::from_mode(0o700))?;
            fs::set_permissions(&hidden_service_dir, fs::Permissions::from_mode(0o700))?;
        }

        // Remove lock file if exists
        let lock_file = tor_data_dir.join("lock");
        if lock_file.exists() {
            let _ = fs::remove_file(&lock_file);
        }

        println!("Starting embedded Tor process...");

        // Get the Tor binary path (bundled or system)
        let tor_binary = get_tor_binary_path();
        
        // Prepare the command
        let mut tor_cmd_builder = Command::new(&tor_binary);
        
        // Set library paths for bundled Tor (Linux: LD_LIBRARY_PATH, macOS: DYLD_LIBRARY_PATH)
        setup_tor_environment(&mut tor_cmd_builder);
        
        // Start Tor process
        let tor_cmd = tor_cmd_builder
            .args([
                "--SocksPort",
                &config::TOR_SOCKS_PORT.to_string(),
                "--ControlPort",
                &config::TOR_CONTROL_PORT.to_string(),
                "--DataDirectory",
                &tor_data_dir.to_string_lossy(),
                "--HiddenServiceDir",
                &hidden_service_dir.to_string_lossy(),
                "--HiddenServicePort",
                &format!(
                    "{} 127.0.0.1:{}",
                    config::HIDDEN_SERVICE_VIRTUAL_PORT,
                    self.port
                ),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| TorError::StartFailed(e.to_string()))?;

        *self.tor_process.lock().unwrap() = Some(tor_cmd);

        println!("✓ Tor process started (bootstrapping in background...)");

        // Start thread to monitor Tor output
        self.start_tor_monitor();

        // Wait for hidden service hostname
        println!("Waiting for hidden service to be created...");
        let hostname_file = hidden_service_dir.join("hostname");

        for i in 0..30 {
            if hostname_file.exists() {
                if let Ok(hostname) = fs::read_to_string(&hostname_file) {
                    let onion = hostname.trim().to_string();
                    println!("✓ Onion address: {}", onion);
                    *self.onion_address.lock().unwrap() = Some(onion);
                    break;
                }
            }
            thread::sleep(Duration::from_secs(1));
            if i % 5 == 0 && i > 0 {
                println!("  Still waiting... ({}s)", i);
            }
        }

        if self.onion_address.lock().unwrap().is_none() {
            println!("⚠️  Onion address not yet available");
            println!("   Tor is still bootstrapping. Check back in a minute.");
            println!("   You can find your address in: {:?}", hostname_file);
        }

        // Start the server socket
        self.start_server()?;

        Ok(true)
    }

    /// Start monitoring Tor process output
    fn start_tor_monitor(&self) {
        let tor_process = Arc::clone(&self.tor_process);
        let bootstrap_callback = Arc::clone(&self.bootstrap_callback);

        thread::spawn(move || {
            let bootstrap_regex = Regex::new(r"Bootstrapped (\d+)%").unwrap();
            let status_regex = Regex::new(r"Bootstrapped \d+% \(([^)]+)\)").unwrap();

            loop {
                let stdout = {
                    let mut proc_guard = tor_process.lock().unwrap();
                    if let Some(ref mut proc) = *proc_guard {
                        proc.stdout.take()
                    } else {
                        break;
                    }
                };

                if let Some(stdout) = stdout {
                    let reader = BufReader::new(stdout);
                    for line in reader.lines() {
                        if let Ok(line) = line {
                            if !line.is_empty() {
                                println!("Tor: {}", line);
                            }

                            // Extract bootstrap information
                            if line.contains("Bootstrapped") {
                                if let Some(caps) = bootstrap_regex.captures(&line) {
                                    if let Some(percent_match) = caps.get(1) {
                                        if let Ok(percentage) = percent_match.as_str().parse::<u32>()
                                        {
                                            let status = status_regex
                                                .captures(&line)
                                                .and_then(|c| c.get(1))
                                                .map(|m| m.as_str())
                                                .unwrap_or("Connecting");

                                            // Call callback
                                            if let Ok(cb_guard) = bootstrap_callback.lock() {
                                                if let Some(ref callback) = *cb_guard {
                                                    callback(percentage, status);
                                                }
                                            }

                                            if percentage == 100 {
                                                println!("✓ Tor fully bootstrapped!");
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                break;
            }
        });
    }

    /// Start the TCP server to listen for incoming connections
    fn start_server(&self) -> Result<(), TorError> {
        let listener = TcpListener::bind(format!("127.0.0.1:{}", self.port))?;
        println!("Server listening on 127.0.0.1:{}", self.port);

        self.is_running.store(true, Ordering::SeqCst);

        let is_running = Arc::clone(&self.is_running);
        let message_handler = Arc::clone(&self.message_handler);
        let onion_address = Arc::clone(&self.onion_address);
        let templates_dir = self.templates_dir.clone();

        thread::spawn(move || {
            for stream in listener.incoming() {
                if !is_running.load(Ordering::SeqCst) {
                    break;
                }

                if let Ok(stream) = stream {
                    let mh = Arc::clone(&message_handler);
                    let onion = Arc::clone(&onion_address);
                    let templates = templates_dir.clone();

                    thread::spawn(move || {
                        if let Err(e) = handle_client(stream, mh, onion, templates) {
                            eprintln!("Error handling client: {}", e);
                        }
                    });
                }
            }
        });

        Ok(())
    }

    /// Send a message to another peer via Tor
    pub fn send_message(&self, onion_address: &str, message: &str) -> Result<bool, TorError> {
        // Parse onion address and port
        // When connecting to .onion addresses, we need to use the VIRTUAL port (80)
        // NOT the local port (8080). The hidden service maps 80 -> 8080 internally.
        let (host, port) = if onion_address.contains(':') {
            let parts: Vec<&str> = onion_address.rsplitn(2, ':').collect();
            (
                parts[1].to_string(),
                parts[0].parse::<u16>().unwrap_or(config::HIDDEN_SERVICE_VIRTUAL_PORT),
            )
        } else {
            (onion_address.to_string(), config::HIDDEN_SERVICE_VIRTUAL_PORT)
        };

        // Create SOCKS5 connection through Tor
        let proxy_addr = format!("127.0.0.1:{}", config::TOR_SOCKS_PORT);

        // Use socks crate for SOCKS5 proxy connection
        let stream = socks::Socks5Stream::connect(
            proxy_addr.as_str(),
            (host.as_str(), port),
        )
        .map_err(|e| TorError::Connection(e.to_string()))?;

        let mut socket = stream.into_inner();
        socket
            .set_read_timeout(Some(Duration::from_secs(config::CONNECTION_TIMEOUT)))
            .ok();
        socket
            .set_write_timeout(Some(Duration::from_secs(config::CONNECTION_TIMEOUT)))
            .ok();

        // Send the message
        socket.write_all(message.as_bytes())?;
        socket.write_all(b"\n")?;
        socket.flush()?;

        // Wait for acknowledgment
        let mut response = [0u8; 1024];
        let n = socket.read(&mut response)?;

        Ok(&response[..n].trim_ascii() == b"OK")
    }

    /// Stop the Tor service and embedded Tor process
    pub fn stop(&self) {
        self.is_running.store(false, Ordering::SeqCst);

        // Stop Tor process
        if let Some(mut proc) = self.tor_process.lock().unwrap().take() {
            println!("Stopping Tor process...");
            let _ = proc.kill();
            let _ = proc.wait();
        }

        // Kill any remaining Tor processes
        Self::kill_existing_tor_processes();

        // Remove lock file
        let lock_file = config::tor_data_dir().join("lock");
        if lock_file.exists() {
            let _ = fs::remove_file(&lock_file);
        }

        println!("Tor service stopped");
    }

    /// Get the onion address of this service
    pub fn get_onion_address(&self) -> Option<String> {
        let addr = self.onion_address.lock().unwrap();
        if addr.is_some() {
            return addr.clone();
        }

        // Try to read from hostname file
        let hostname_file = config::hidden_service_dir().join("hostname");
        if hostname_file.exists() {
            if let Ok(hostname) = fs::read_to_string(&hostname_file) {
                return Some(hostname.trim().to_string());
            }
        }
        None
    }

    /// Check if Tor process is running
    pub fn is_tor_running(&self) -> bool {
        if let Some(ref mut proc) = *self.tor_process.lock().unwrap() {
            return proc.try_wait().ok().flatten().is_none();
        }

        // Check SOCKS port as fallback
        TcpStream::connect_timeout(
            &format!("127.0.0.1:{}", config::TOR_SOCKS_PORT)
                .parse()
                .unwrap(),
            Duration::from_secs(2),
        )
        .is_ok()
    }
}

impl Drop for TorService {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Handle a client connection - supports both HTTP and custom protocol
fn handle_client(
    mut stream: TcpStream,
    message_handler: Arc<Mutex<Option<MessageHandler>>>,
    onion_address: Arc<Mutex<Option<String>>>,
    templates_dir: PathBuf,
) -> Result<(), TorError> {
    let mut data = Vec::new();
    let mut buf = [0u8; 4096];

    stream.set_read_timeout(Some(Duration::from_secs(5)))?;

    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                data.extend_from_slice(&buf[..n]);
                // Check for end of message
                if data.contains(&b'\n') || data.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(e) => return Err(TorError::Io(e)),
        }
    }

    if data.is_empty() {
        return Ok(());
    }

    // Check if it's an HTTP request
    if data.starts_with(b"GET ") || data.starts_with(b"POST ") || data.starts_with(b"HEAD ") {
        handle_http_request(&mut stream, &data, message_handler, onion_address, templates_dir)?;
    } else {
        // Custom messaging protocol
        if let Ok(mh) = message_handler.lock() {
            if let Some(ref handler) = *mh {
                let message_str = String::from_utf8_lossy(&data).trim().to_string();
                handler(message_str);
            }
        }
        stream.write_all(b"OK\n")?;
    }

    Ok(())
}

/// Handle HTTP request from a web browser
fn handle_http_request(
    stream: &mut TcpStream,
    request_data: &[u8],
    message_handler: Arc<Mutex<Option<MessageHandler>>>,
    onion_address: Arc<Mutex<Option<String>>>,
    templates_dir: PathBuf,
) -> Result<(), TorError> {
    let request_str = String::from_utf8_lossy(request_data);
    let lines: Vec<&str> = request_str.split("\r\n").collect();
    let request_line = lines.first().unwrap_or(&"");
    let parts: Vec<&str> = request_line.split_whitespace().collect();

    let method = parts.get(0).unwrap_or(&"GET");
    let path = parts.get(1).unwrap_or(&"/");

    // Handle POST request (message submission)
    if *method == "POST" && path.contains("/send") {
        return handle_post_message(stream, &request_str, message_handler, &templates_dir);
    }

    // Handle GET request for sent messages confirmation
    if path.contains("/sent") {
        let html = load_template(&templates_dir, "sent.html");
        return send_http_response(stream, &html, "200 OK");
    }

    // Serve main page
    let mut html = load_template(&templates_dir, "index.html");
    let onion = onion_address
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_else(|| "Loading...".to_string());
    html = html.replace("{{ONION_ADDRESS}}", &onion);
    send_http_response(stream, &html, "200 OK")
}

/// Handle POST request for sending messages
fn handle_post_message(
    stream: &mut TcpStream,
    request_str: &str,
    message_handler: Arc<Mutex<Option<MessageHandler>>>,
    templates_dir: &PathBuf,
) -> Result<(), TorError> {
    // Parse POST body
    let body = request_str
        .split("\r\n\r\n")
        .nth(1)
        .unwrap_or("");

    // Parse form data (URL encoded)
    let mut form_data: HashMap<String, String> = HashMap::new();
    for pair in body.split('&') {
        let mut parts = pair.splitn(2, '=');
        if let (Some(key), Some(value)) = (parts.next(), parts.next()) {
            let decoded = urlencoding::decode(value).unwrap_or_default().to_string();
            form_data.insert(key.to_string(), decoded);
        }
    }

    let sender = form_data
        .get("sender")
        .cloned()
        .unwrap_or_else(|| "Anonymous".to_string());
    let message = form_data.get("message").cloned().unwrap_or_default();

    if !message.is_empty() {
        // Create a web message and pass to handler
        let web_message = WebMessage {
            msg_type: "web_message".to_string(),
            sender: sender.clone(),
            text: message.clone(),
            timestamp: chrono::Utc::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        };

        if let Ok(mh) = message_handler.lock() {
            if let Some(ref handler) = *mh {
                if let Ok(json) = serde_json::to_string(&web_message) {
                    handler(json);
                }
            }
        }

        println!("📨 Web message from '{}': {}", sender, message);

        let html = load_template(templates_dir, "sent.html");
        return send_http_response(stream, &html, "200 OK");
    }

    let mut html = load_template(templates_dir, "error.html");
    html = html.replace("{{ERROR_MESSAGE}}", "Message cannot be empty");
    send_http_response(stream, &html, "400 Bad Request")
}

/// Load HTML template from templates directory
fn load_template(templates_dir: &PathBuf, template_name: &str) -> String {
    let template_path = templates_dir.join(template_name);

    if template_path.exists() {
        fs::read_to_string(&template_path).unwrap_or_else(|_| {
            format!(
                "<html><body><h1>Error loading template: {}</h1></body></html>",
                template_name
            )
        })
    } else {
        format!(
            "<html><body><h1>Template not found: {}</h1></body></html>",
            template_name
        )
    }
}

/// Send HTTP response to client
fn send_http_response(stream: &mut TcpStream, html_content: &str, status: &str) -> Result<(), TorError> {
    let response = format!(
        "HTTP/1.1 {}\r\n\
         Content-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {}",
        status,
        html_content.len(),
        html_content
    );

    stream.write_all(response.as_bytes())?;
    stream.flush()?;
    Ok(())
}
