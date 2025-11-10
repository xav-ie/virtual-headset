use uhid_virt::{Bus, CreateParams, UHIDDevice, StreamError, OutputEvent};
use std::fs::File;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use crossterm::{
    terminal::{disable_raw_mode, enable_raw_mode},
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
};
use dialoguer::Select;

mod hid_descriptor;
use hid_descriptor::TELEPHONY_DESCRIPTOR;

mod pipewire;
use pipewire::AudioSource;

struct DeviceState {
    muted: bool,
}

impl DeviceState {
    fn new() -> Self {
        Self { muted: false }
    }

    fn toggle_mute(&mut self) {
        self.muted = !self.muted;
    }
}

fn select_audio_source() -> Result<AudioSource, Box<dyn std::error::Error>> {
    println!("Scanning for audio input sources...\n");

    let sources = pipewire::list_sources()?;

    if sources.is_empty() {
        return Err("No audio sources found".into());
    }

    let descriptions: Vec<&str> = sources.iter().map(|s| s.description.as_str()).collect();

    let selection = Select::new()
        .with_prompt("Select audio input source")
        .items(&descriptions)
        .default(0)
        .interact()?;

    Ok(sources[selection].clone())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Set up Ctrl+C handler
    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();

    ctrlc::set_handler(move || {
        // Ensure terminal is restored on Ctrl+C
        let _ = disable_raw_mode();
        r.store(false, Ordering::SeqCst);
        eprintln!("\nReceived Ctrl+C, shutting down...");
    })?;

    // Select audio source
    let selected_source = select_audio_source()?;
    println!("\n✓ Selected: {}\n", selected_source.description);

    // Start pw-loopback to create virtual microphone
    println!("Starting PipeWire loopback...");
    let mut loopback_process = pipewire::start_loopback(&selected_source.name)?;
    println!("✓ Virtual microphone created\n");

    // Small delay to let PipeWire settle
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Create HID device
    println!("Creating virtual HID telephony device...");
    let params = CreateParams {
        name: "Virtual_Headset".to_string(),  // Must match audio device name for Zoom
        phys: String::new(),
        uniq: String::new(),
        bus: Bus::USB,
        vendor: 0x0b0e,  // Jabra vendor ID - kernel has special driver for it!
        product: 0x245e, // Jabra Evolve2 65 product ID
        version: 1,
        country: 0,
        rd_data: TELEPHONY_DESCRIPTOR.to_vec(),
    };

    let mut device = UHIDDevice::<File>::create(params)?;
    println!("✓ HID device created successfully!");
    println!("  Check /dev/hidraw* for the new device\n");

    let mut state = DeviceState::new();

    // Send initial state: off-hook (bit 0 = 1), unmuted (bit 1 = 0)
    device.write(&[0x01, 0x01])?;

    println!("Controls:");
    println!("  m      - Toggle mute");
    println!("  q/Esc  - Quit");
    println!("\nReady. Press 'm' to toggle mute.");

    // Enable raw mode for keyboard input (after printing initial messages)
    enable_raw_mode()?;

    // Main event loop
    while running.load(Ordering::SeqCst) {
        // Check for keyboard input (non-blocking with timeout)
        if event::poll(std::time::Duration::from_millis(100))?
            && let Event::Key(KeyEvent { code, modifiers, .. }) = event::read()? {
                match code {
                    KeyCode::Char('c') | KeyCode::Char('C') if modifiers.contains(KeyModifiers::CONTROL) => {
                        running.store(false, Ordering::SeqCst);
                    }
                    KeyCode::Char('m') | KeyCode::Char('M') => {
                        state.toggle_mute();

                        // Send HID mute button pulse (0→1→0 toggles mute state)
                        // Hook bit stays 1 (off-hook) throughout
                        device.write(&[0x01, 0x03])?; // hook=1, mute=1
                        std::thread::sleep(std::time::Duration::from_millis(50));
                        device.write(&[0x01, 0x01])?; // hook=1, mute=0

                        print!("Mute: {}\r\n", if state.muted { "ON" } else { "OFF" });
                    }
                    KeyCode::Char('q') | KeyCode::Char('Q') => {
                        running.store(false, Ordering::SeqCst);
                    }
                    KeyCode::Esc => {
                        running.store(false, Ordering::SeqCst);
                    }
                    _ => {}
                }
            }

        // Try to read events from device (LED feedback from host)
        // This helps us see if Zoom/Meet is communicating with the device
        match device.read() {
            Ok(event) => {
                match event {
                    OutputEvent::Output { data } => {
                        if data.len() >= 2 && data[0] == 0x02 {
                            let mute = (data[1] & 0x01) != 0;
                            let hook = (data[1] & 0x02) != 0;
                            let ring = (data[1] & 0x04) != 0;
                            print!("Host LEDs → Mute:{}, Hook:{}, Ring:{}\r\n", mute, hook, ring);
                        }
                    }
                    OutputEvent::GetReport { id, report_number, report_type } => {
                        print!("GetReport: id={}, num={}, type={:?}\r\n", id, report_number, report_type);

                        // Respond with current state: hook=1 (always off-hook), mute bit varies
                        let state_bits = 0x01 | ((state.muted as u8) << 1);
                        if let Err(e) = device.write_get_report_reply(id, 0, vec![state_bits]) {
                            print!("Failed to reply: {}\r\n", e);
                        }
                    }
                    OutputEvent::SetReport { id, .. } => {
                        // Acknowledge SetReport
                        let _ = device.write_set_report_reply(id, 0);
                    }
                    OutputEvent::Start { .. } => {
                        print!("Device opened by host\r\n");
                    }
                    OutputEvent::Open => {
                        print!("Device connected\r\n");
                    }
                    OutputEvent::Stop | OutputEvent::Close => {
                        // Silently handle disconnect events
                    }
                }
            }
            Err(StreamError::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // No data available, normal
            }
            Err(StreamError::Io(e)) => {
                print!("IO error: {}\r\n", e);
            }
            Err(StreamError::UnknownEventType(t)) => {
                print!("Unknown event: {}\r\n", t);
            }
        }
    }

    // Cleanup
    disable_raw_mode()?;
    print!("\r\nShutting down...\r\n");

    // Kill pw-loopback process
    if let Err(e) = loopback_process.kill() {
        eprintln!("Warning: Failed to kill loopback process: {}", e);
    } else {
        println!("✓ Stopped PipeWire loopback");
    }

    Ok(())
}
