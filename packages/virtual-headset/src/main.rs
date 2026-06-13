use atty::Stream;
use crossbeam_channel::unbounded;
use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    terminal::{disable_raw_mode, enable_raw_mode},
};
use std::fs::File;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use uhid_virt::{Bus, CreateParams, OutputEvent, StreamError, UHIDDevice};

mod hid_descriptor;
use hid_descriptor::TELEPHONY_DESCRIPTOR;

mod pipewire;

mod dbus_interface;
use dbus_interface::DBusService;

/// Helper macro to print with appropriate line endings based on terminal mode
macro_rules! print_msg {
    ($is_interactive:expr, $($arg:tt)*) => {
        if $is_interactive {
            print!($($arg)*);
            print!("\r\n");
        } else {
            println!($($arg)*);
        }
    };
}

struct DeviceState {
    muted: bool,
}

impl DeviceState {
    fn new() -> Self {
        // Start muted so the mic is never hot on (re)start before you opt in.
        Self { muted: true }
    }

    fn toggle_mute(&mut self) {
        self.muted = !self.muted;
    }
}

/// Drive the audio gate toward the state implied by `muted`, retrying until it
/// sticks.
///
/// `processing_linked` is the last state we *successfully* applied (`None` until
/// the first success). We only shell out to pw-link on a real divergence, and
/// only advance the tracked state when the gate actually ran — so a transient
/// pw-link/PipeWire failure is retried on the next reconcile rather than being
/// silently assumed applied.
fn reconcile_link(
    source_name: &str,
    muted: bool,
    processing_linked: &mut Option<bool>,
    is_interactive: bool,
) {
    let want_linked = !muted;
    if *processing_linked != Some(want_linked)
        && pipewire::set_capture_linked(source_name, want_linked)
    {
        *processing_linked = Some(want_linked);
        print_msg!(
            is_interactive,
            "Audio chain {}",
            if want_linked {
                "resumed (unmuted)"
            } else {
                "suspended (muted)"
            }
        );
    }
}

/// Apply one mute toggle received over D-Bus: flip the state, gate the audio,
/// pulse the HID mute button so the host app (Zoom/Meet) sees it, and sync D-Bus
/// listeners.
///
/// The audio relink happens first, before the 50ms HID button pulse, so an
/// unmute is audible in ~16ms instead of waiting out the pulse — the host
/// notification is not on the audio path and can lag a few ms.
fn apply_dbus_toggle(
    state: &mut DeviceState,
    device: &mut UHIDDevice<File>,
    dbus: &Option<DBusService>,
    is_interactive: bool,
    source_name: &str,
    processing_linked: &mut Option<bool>,
) -> Result<(), Box<dyn std::error::Error>> {
    state.toggle_mute();

    reconcile_link(source_name, state.muted, processing_linked, is_interactive);

    print_msg!(
        is_interactive,
        "D-Bus toggle received, muting: {}",
        state.muted
    );

    // Send HID mute button pulse (0→1→0 toggles mute state); hook bit stays 1.
    device.write(&[0x01, 0x03])?; // hook=1, mute=1
    std::thread::sleep(std::time::Duration::from_millis(50));
    device.write(&[0x01, 0x01])?; // hook=1, mute=0

    if let Some(dbus) = dbus {
        dbus.state().set(state.muted);
        if let Err(e) = dbus.notify_mute_changed(state.muted) {
            print_msg!(is_interactive, "D-Bus signal error: {}", e);
        }
    }

    print_msg!(
        is_interactive,
        "Mute state updated to: {}",
        if state.muted { "ON" } else { "OFF" }
    );
    Ok(())
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

    // Get default audio source and set up PipeWire loopback
    let is_interactive = atty::is(Stream::Stdin);

    println!("Getting audio input source...");
    let source = pipewire::get_source()?;
    println!("✓ Using source: {}\n", source.description);

    // Start pw-loopback to create virtual microphone. First sweep any loopback
    // orphaned by a previous instance that didn't exit gracefully (SIGKILL, or a
    // SIGTERM before its handler ran), so we never accrete duplicate
    // Virtual_Headset_Mic sources.
    println!("Starting PipeWire loopback...");
    pipewire::kill_existing_loopbacks();
    let mut loopback_process = pipewire::start_loopback(&source.name)?;
    println!("✓ Virtual microphone created\n");

    // Small delay to let PipeWire settle
    std::thread::sleep(std::time::Duration::from_millis(500));

    // Create HID device
    println!("Creating virtual HID telephony device...");
    let params = CreateParams {
        name: "Virtual_Headset".to_string(), // Must match audio device name for Zoom
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

    // Create channel for D-Bus toggle commands
    let (toggle_tx, toggle_rx) = unbounded();

    // Initialize D-Bus service for status bar integration
    let dbus = match DBusService::new(toggle_tx) {
        Ok(dbus) => {
            println!("✓ D-Bus service registered: com.github.virtual_headset");
            Some(dbus)
        }
        Err(e) => {
            println!("⚠ D-Bus service failed (will continue without it): {}", e);
            None
        }
    };

    let mut state = DeviceState::new();

    // Send initial HID input report: off-hook (bit 0 = 1) + mute bit (bit 1)
    // reflecting the initial state, so apps that query on connect see it.
    let hook_bit = 0x01;
    let initial_report = hook_bit | ((state.muted as u8) << 1);
    device.write(&[0x01, initial_report])?;

    // Sync the initial mute state onto D-Bus and notify listeners (Waybar, the
    // browser bridge) so they reflect "muted" right after (re)start.
    if let Some(ref dbus) = dbus {
        dbus.state().set(state.muted);
        if let Err(e) = dbus.notify_mute_changed(state.muted) {
            print_msg!(is_interactive, "D-Bus signal error: {}", e);
        }
    }

    // Reflect the initial mute state onto the audio graph. We start muted, so cut
    // the denoised source out of the loopback: the RNNoise filter and raw mic
    // suspend to ~0% while the loopback still feeds silence into
    // Virtual_Headset_Mic (the device stays present for the call app).
    //
    // Wait for wireplumber to create the loopback's auto-link first, so the cut
    // acts on a real link instead of racing ahead of the async auto-link — which
    // would leave the chain wired while muted, with no later reconcile to fix it
    // (the state would already look applied). Bounded so we never hang.
    for _ in 0..30 {
        if pipewire::capture_link_exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    // Last successfully-applied link state (None until the first success); the
    // reconcile retries until the gate actually takes.
    let mut processing_linked: Option<bool> = None;
    reconcile_link(
        &source.name,
        state.muted,
        &mut processing_linked,
        is_interactive,
    );

    if is_interactive {
        println!("Controls:");
        println!("  m      - Toggle mute");
        println!("  q/Esc  - Quit");
        println!("\nReady. Press 'm' to toggle mute.");

        // Enable raw mode for keyboard input (after printing initial messages)
        enable_raw_mode()?;
    } else {
        println!("Running in daemon mode. Use D-Bus to control mute state.");
    }

    // Main event loop
    while running.load(Ordering::SeqCst) {
        // Wait for the next D-Bus toggle. In daemon mode we BLOCK on the channel
        // (with a 100ms cap so HID events still get serviced) instead of
        // busy-polling + sleeping — so an unmute from the panel/CLI wakes us
        // instantly (~16ms resume) rather than waiting out a poll interval. The
        // channel is the portable seam: any platform IPC feeds it, and this loop
        // never has to know about D-Bus specifically. In interactive mode the
        // keyboard poll below sets the cadence, so we just drain non-blocking.
        if !is_interactive {
            match toggle_rx.recv_timeout(std::time::Duration::from_millis(100)) {
                Ok(()) => apply_dbus_toggle(
                    &mut state,
                    &mut device,
                    &dbus,
                    is_interactive,
                    &source.name,
                    &mut processing_linked,
                )?,
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                // D-Bus unavailable (registration failed): no toggles will ever
                // arrive, so recv returns instantly — sleep to avoid busy-spin
                // while HID-driven mute still works via device.read() below.
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }
        // Drain any further queued toggles (and all of them in interactive mode).
        while let Ok(()) = toggle_rx.try_recv() {
            apply_dbus_toggle(
                &mut state,
                &mut device,
                &dbus,
                is_interactive,
                &source.name,
                &mut processing_linked,
            )?;
            // Don't let a burst of queued toggles (each sleeping 50ms in the HID
            // pulse) delay shutdown.
            if !running.load(Ordering::SeqCst) {
                break;
            }
        }

        // Backstop reconcile for mute changes that don't go through
        // `apply_dbus_toggle` (keyboard 'm', host-driven HID mute below), and a
        // retry for any gate that previously failed to apply. The D-Bus path
        // already relinked above, so this only acts on a real divergence.
        reconcile_link(
            &source.name,
            state.muted,
            &mut processing_linked,
            is_interactive,
        );

        // Check for keyboard input (non-blocking with timeout) - only in interactive mode
        if is_interactive
            && event::poll(std::time::Duration::from_millis(100))?
            && let Event::Key(KeyEvent {
                code, modifiers, ..
            }) = event::read()?
        {
            match code {
                KeyCode::Char('c') | KeyCode::Char('C')
                    if modifiers.contains(KeyModifiers::CONTROL) =>
                {
                    running.store(false, Ordering::SeqCst);
                }
                KeyCode::Char('m') | KeyCode::Char('M') => {
                    state.toggle_mute();

                    print!("Keyboard toggle, ");

                    // Send HID mute button pulse (0→1→0 toggles mute state)
                    // Hook bit stays 1 (off-hook) throughout
                    device.write(&[0x01, 0x03])?; // hook=1, mute=1
                    std::thread::sleep(std::time::Duration::from_millis(50));
                    device.write(&[0x01, 0x01])?; // hook=1, mute=0

                    // Update D-Bus and send signal
                    if let Some(ref dbus) = dbus {
                        dbus.state().set(state.muted);
                        if let Err(e) = dbus.notify_mute_changed(state.muted) {
                            print_msg!(is_interactive, "D-Bus signal error: {}", e);
                        }
                    }

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
                        if data.len() < 2 {
                            continue;
                        }

                        // Handle LED state OUTPUT (report ID 2)
                        if data[0] == 0x02 {
                            let mute_led = (data[1] & 0x01) != 0;
                            let hook = (data[1] & 0x02) != 0;
                            let ring = (data[1] & 0x04) != 0;

                            // Sync internal state with what host requested
                            state.muted = mute_led;

                            // Update D-Bus state and notify listeners
                            if let Some(ref dbus) = dbus {
                                dbus.state().set(state.muted);
                                if let Err(e) = dbus.notify_mute_changed(state.muted) {
                                    print_msg!(is_interactive, "D-Bus signal error: {}", e);
                                }
                            }

                            print_msg!(
                                is_interactive,
                                "← OUTPUT: mute={}, hook={}, ring={} (LED state from host)",
                                mute_led,
                                hook,
                                ring
                            );
                        }
                        // Handle control command OUTPUT (report ID 3)
                        else if data[0] == 0x03 {
                            let command = data[1];
                            match command {
                                0x01 if !state.muted => {
                                    // Mute command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← OUTPUT: mute command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                0x02 if state.muted => {
                                    // Unmute command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← OUTPUT: unmute command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                0x03 => {
                                    // Toggle command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← OUTPUT: toggle command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                _ => {}
                            }
                        }
                    }
                    OutputEvent::GetReport {
                        id,
                        report_number,
                        report_type,
                    } => {
                        print!(
                            "GetReport: id={}, num={}, type={:?}\r\n",
                            id, report_number, report_type
                        );

                        // Respond with current state: hook=1 (always off-hook), mute bit varies
                        let state_bits = 0x01 | ((state.muted as u8) << 1);
                        if let Err(e) = device.write_get_report_reply(id, 0, vec![state_bits]) {
                            print!("Failed to reply: {}\r\n", e);
                        }
                    }
                    OutputEvent::SetReport {
                        id,
                        report_type,
                        data,
                        ..
                    } => {
                        use uhid_virt::ReportType;
                        // Handle feature report control commands
                        if report_type == ReportType::Feature && data.len() >= 2 && data[0] == 0x03
                        {
                            let command = data[1];
                            match command {
                                0x01 if !state.muted => {
                                    // Mute command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← FEATURE: mute command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                0x02 if state.muted => {
                                    // Unmute command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← FEATURE: unmute command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                0x03 => {
                                    // Toggle command
                                    state.toggle_mute();
                                    print_msg!(is_interactive, "← FEATURE: toggle command");

                                    // Send INPUT report
                                    device.write(&[0x01, 0x03])?;
                                    std::thread::sleep(std::time::Duration::from_millis(50));
                                    device.write(&[0x01, 0x01])?;

                                    // Update D-Bus
                                    if let Some(ref dbus) = dbus {
                                        dbus.state().set(state.muted);
                                        let _ = dbus.notify_mute_changed(state.muted);
                                    }
                                }
                                _ => {}
                            }
                        }

                        // Acknowledge SetReport
                        let _ = device.write_set_report_reply(id, 0);
                    }
                    OutputEvent::Start { .. } => {
                        if is_interactive {
                            print!("Device opened by host\r\n");
                        }
                    }
                    OutputEvent::Open => {
                        if is_interactive {
                            print!("Device connected\r\n");
                        }
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
    if is_interactive {
        disable_raw_mode()?;
        print!("\r\nShutting down...\r\n");
    } else {
        println!("Shutting down...");
    }

    // Kill pw-loopback process
    if let Err(e) = loopback_process.kill() {
        eprintln!("Warning: Failed to kill loopback process: {}", e);
    } else {
        println!("✓ Stopped PipeWire loopback");
    }

    Ok(())
}
