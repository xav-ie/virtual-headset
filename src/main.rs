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
    off_hook: bool,
}

impl DeviceState {
    fn new() -> Self {
        Self {
            muted: false,
            off_hook: true,
        }
    }

    fn toggle_mute(&mut self) -> bool {
        self.muted = !self.muted;
        self.muted
    }

    fn toggle_hook(&mut self) -> bool {
        self.off_hook = !self.off_hook;
        self.off_hook
    }

    fn to_report(&self) -> [u8; 2] {
        // Report format: [Report ID, bits: bit0=hook, bit1=mute, bit2-7=padding]
        let bits = (self.off_hook as u8) | ((self.muted as u8) << 1);
        [0x01, bits]
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

    // Send initial state
    device.write(&state.to_report())?;

    println!("Controls:");
    println!("  m - Toggle mute");
    println!("  h - Toggle hook (on-hook/off-hook)");
    println!("  q - Quit");
    println!("  Ctrl+C - Quit");
    println!("\nStatus: OFF-HOOK, UNMUTED");

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
                        // Toggle internal state for display
                        state.toggle_mute();

                        // Report ID 1: Telephony INPUT (Hook=Absolute, Mute=Relative)
                        // For Relative OOC: send pulse (0→1→0 toggles)
                        // Hook stays at current state (off-hook=1), Mute pulses to toggle

                        // PRESS: mute bit = 1
                        let press_bits = (state.off_hook as u8) | (1 << 1);
                        device.write(&[0x01, press_bits])?;
                        print!("Mute: PRESS (0x{:02x})\r\n", press_bits);

                        std::thread::sleep(std::time::Duration::from_millis(50));

                        // RELEASE: mute bit = 0 (no-op for Relative, but required before next toggle)
                        let release_bits = state.off_hook as u8;
                        device.write(&[0x01, release_bits])?;
                        print!("Mute: RELEASE (0x{:02x})\r\n", release_bits);

                        // Also send to Report ID 3 (System Microphone Mute) for Google Meet
                        device.write(&[0x03, 0x01])?;
                        std::thread::sleep(std::time::Duration::from_millis(50));
                        device.write(&[0x03, 0x00])?;

                        print!("Status: {}, {}\r\n",
                            if state.off_hook { "OFF-HOOK" } else { "ON-HOOK" },
                            if state.muted { "MUTED" } else { "UNMUTED" }
                        );
                    }
                    KeyCode::Char('h') | KeyCode::Char('H') => {
                        state.toggle_hook();
                        // Hook is Absolute - send the new state directly
                        // Mute bit stays 0 (we don't toggle mute here)
                        let report_bits = state.off_hook as u8;
                        device.write(&[0x01, report_bits])?;
                        print!("Hook state changed\r\n");
                        print!("Status: {}, {}\r\n",
                            if state.off_hook { "OFF-HOOK" } else { "ON-HOOK" },
                            if state.muted { "MUTED" } else { "UNMUTED" }
                        );
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
                            // Report ID 2: LED states from Zoom
                            let mute_led = (data[1] & 0x01) != 0;
                            let offhook_led = (data[1] & 0x02) != 0;
                            let ring_led = (data[1] & 0x04) != 0;
                            print!("Zoom LEDs → Mute:{}, OffHook:{}, Ring:{}\r\n",
                                   mute_led, offhook_led, ring_led);
                        } else {
                            print!("Received Output: {:?}\r\n", data);
                        }
                    }
                    OutputEvent::GetReport { id, report_number, report_type } => {
                        print!("Received GetReport: id={}, report_number={}, report_type={:?}\r\n", id, report_number, report_type);

                        // Respond with current state
                        let report = state.to_report();
                        let response_data = vec![report[1]];
                        if let Err(e) = device.write_get_report_reply(id, 0, response_data) {
                            print!("Failed to send GetReport reply: {}\r\n", e);
                        } else {
                            print!("Sent GetReport reply: state=0x{:02x}\r\n", report[1]);
                        }
                    }
                    OutputEvent::SetReport { id, report_number, report_type, data } => {
                        print!("Received SetReport: id={}, report_number={}, report_type={:?}, data={:?}\r\n", id, report_number, report_type, data);

                        // Acknowledge SetReport
                        if let Err(e) = device.write_set_report_reply(id, 0) {
                            print!("Failed to send SetReport reply: {}\r\n", e);
                        }
                    }
                    OutputEvent::Start { .. } => {
                        print!("Received Start event - device opened by host\r\n");
                    }
                    OutputEvent::Stop => {
                        print!("Received Stop event\r\n");
                    }
                    OutputEvent::Open => {
                        print!("Received Open event\r\n");
                    }
                    OutputEvent::Close => {
                        print!("Received Close event\r\n");
                    }
                }
            }
            Err(StreamError::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                // No data available, that's fine
            }
            Err(StreamError::Io(e)) => {
                print!("Read IO error: {}\r\n", e);
            }
            Err(StreamError::UnknownEventType(t)) => {
                print!("Unknown event type: {}\r\n", t);
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
