use atty::Stream;
use crossbeam_channel::unbounded;
use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers},
    terminal::{disable_raw_mode, enable_raw_mode},
};
use std::fs::File;
use std::io::Read;
use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use uhid_virt::{Bus, CreateParams, OutputEvent, StreamError, UHIDDevice};

mod dbus_interface;
mod hid_descriptor;
mod pipewire;
mod settings;

use dbus_interface::{Command, DBusService, State};
use hid_descriptor::TELEPHONY_DESCRIPTOR;
use settings::Settings;

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
    /// A call app has the headset off-hook (its LED report, bit 1).
    in_call: bool,
}

impl DeviceState {
    fn new() -> Self {
        // Start muted so the mic is never hot on (re)start before you opt in.
        Self {
            muted: true,
            in_call: false,
        }
    }

    fn toggle_mute(&mut self) {
        self.muted = !self.muted;
    }
}

/// What the daemon knows that isn't device state: the settings it runs with
/// and how to reach D-Bus. Turns device state into the published `State`.
struct Daemon {
    dbus: Option<DBusService>,
    settings: Settings,
    denoise_available: bool,
    source: pipewire::AudioSource,
    is_interactive: bool,
}

impl Daemon {
    fn state(&self, device: &DeviceState) -> State {
        State {
            call: match (device.in_call, device.muted) {
                (false, _) => "none",
                (true, true) => "muted",
                (true, false) => "unmuted",
            },
            denoise: self.settings.denoise && self.denoise_available,
            denoise_available: self.denoise_available,
            keep_open: self.settings.keep_open,
            muted: device.muted,
            source: self.source.description.clone(),
            strength: self.settings.strength_db,
        }
    }

    /// Sync D-Bus listeners (Waybar, the panel, the browser bridge).
    fn publish(&self, device: &DeviceState) {
        if let Some(dbus) = &self.dbus
            && let Err(e) = dbus.publish(self.state(device))
        {
            print_msg!(self.is_interactive, "D-Bus signal error: {}", e);
        }
    }
}

/// Pulse the HID mute button (0→1→0 toggles mute in the call app); the hook
/// bit stays 1 (off-hook) throughout.
fn press_mute(device: &mut UHIDDevice<File>) -> Result<(), Box<dyn std::error::Error>> {
    device.write(&[0x01, 0x03])?; // hook=1, mute=1
    std::thread::sleep(std::time::Duration::from_millis(50));
    device.write(&[0x01, 0x01])?; // hook=1, mute=0
    Ok(())
}

/// Report the virtual mic's level on D-Bus about 10 times a second while audio
/// flows, from a passive recorder that never opens the mic itself. Restarts
/// the recorder when it ends (e.g. the virtual mic was briefly gone).
fn spawn_meter(dbus: DBusService, meter: Arc<Mutex<Option<Child>>>, running: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let chunk = pipewire::METER_RATE / 10;
        let mut bytes = vec![0u8; chunk * 4];
        while running.load(Ordering::SeqCst) {
            let Ok(mut child) = pipewire::start_meter() else {
                std::thread::sleep(std::time::Duration::from_secs(2));
                continue;
            };
            let mut stdout = child.stdout.take();
            *meter.lock().unwrap() = Some(child);
            while let Some(out) = stdout.as_mut()
                && out.read_exact(&mut bytes).is_ok()
            {
                let power = bytes
                    .chunks_exact(4)
                    .map(|b| f64::from(f32::from_le_bytes([b[0], b[1], b[2], b[3]])).powi(2))
                    .sum::<f64>()
                    / chunk as f64;
                let _ = dbus.publish_level((10.0 * power.log10()).max(-100.0));
            }
            if let Some(mut child) = meter.lock().unwrap().take() {
                let _ = child.kill();
                let _ = child.wait();
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
    });
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

/// Apply one command received over D-Bus. A mute change flips the state,
/// gates the audio, pulses the HID mute button so the host app (Zoom/Meet) sees
/// it, and syncs D-Bus listeners.
///
/// The audio relink happens first, before the 50ms HID button pulse, so an
/// unmute is audible in ~16ms instead of waiting out the pulse — the host
/// notification is not on the audio path and can lag a few ms.
fn apply_command(
    command: Command,
    state: &mut DeviceState,
    device: &mut UHIDDevice<File>,
    daemon: &mut Daemon,
    processing_linked: &mut Option<bool>,
) -> Result<(), Box<dyn std::error::Error>> {
    let is_interactive = daemon.is_interactive;
    match command {
        Command::Mute if state.muted => return Ok(()),
        Command::Unmute if !state.muted => return Ok(()),
        Command::SetStrength(db) => {
            daemon.settings.strength_db = settings::clamp_strength(db);
            let value = daemon.settings.strength_db.to_string();
            if let Err(e) = settings::write("strength", &value) {
                print_msg!(is_interactive, "Couldn't save strength: {}", e);
            }
            if daemon.settings.denoise && !pipewire::set_strength(daemon.settings.strength_db) {
                print_msg!(is_interactive, "Couldn't set the denoiser's strength live");
            }
            daemon.publish(state);
            return Ok(());
        }
        Command::Mute | Command::Unmute | Command::Toggle => {}
    }

    state.toggle_mute();
    reconcile_link(
        &daemon.source.name,
        state.muted,
        processing_linked,
        is_interactive,
    );
    print_msg!(is_interactive, "D-Bus mute change, muting: {}", state.muted);
    press_mute(device)?;
    daemon.publish(state);
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

    let is_interactive = atty::is(Stream::Stdin);

    println!("Getting audio input source...");
    let source = pipewire::get_source()?;
    println!("✓ Using source: {}\n", source.description);

    // Noise suppression needs DeepFilterNet's LADSPA plugin, which the package
    // points to; without it the virtual mic forwards the source as is.
    let settings = Settings::load();
    let ladspa = std::env::var("VIRTUAL_HEADSET_LADSPA")
        .ok()
        .filter(|p| std::path::Path::new(p).exists());

    // Start the virtual microphone. First sweep any instance orphaned by a
    // previous daemon that didn't exit gracefully (SIGKILL, or a SIGTERM before
    // its handler ran), so we never accrete duplicate Virtual_Headset_Mic sources.
    println!("Starting the virtual microphone...");
    pipewire::kill_existing_loopbacks();
    let mut loopback_process =
        pipewire::start_virtual_mic(&source.name, &settings, ladspa.as_deref())?;
    println!(
        "✓ Virtual microphone created{}\n",
        if settings.denoise && ladspa.is_some() {
            ", with noise suppression"
        } else {
            ""
        }
    );

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

    let mut state = DeviceState::new();
    let mut daemon = Daemon {
        dbus: None,
        settings,
        denoise_available: ladspa.is_some(),
        source,
        is_interactive,
    };

    // Commands from D-Bus, applied by the main loop below.
    let (commands_tx, commands_rx) = unbounded();
    match DBusService::new(daemon.state(&state), commands_tx) {
        Ok(dbus) => {
            println!("✓ D-Bus service registered: com.github.virtual_headset");
            daemon.dbus = Some(dbus);
        }
        Err(e) => {
            println!("⚠ D-Bus service failed (will continue without it): {}", e);
        }
    }

    // The level meter's recorder, killed on exit.
    let meter: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
    if let Some(dbus) = &daemon.dbus {
        spawn_meter(dbus.clone(), meter.clone(), running.clone());
    }

    // Send initial HID input report: off-hook (bit 0 = 1) + mute bit (bit 1)
    // reflecting the initial state, so apps that query on connect see it.
    let hook_bit = 0x01;
    let initial_report = hook_bit | ((state.muted as u8) << 1);
    device.write(&[0x01, initial_report])?;

    // Sync the initial state onto D-Bus and notify listeners (Waybar, the panel,
    // the browser bridge) so they reflect "muted" right after (re)start.
    daemon.publish(&state);

    // Reflect the initial mute state onto the audio graph. We start muted, so cut
    // the source out of the virtual mic: the raw mic (and any denoiser) suspends
    // to ~0% while the virtual mic still feeds silence into Virtual_Headset_Mic
    // (the device stays present for the call app).
    //
    // Wait for wireplumber to create the capture's auto-link first, so the cut
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
        &daemon.source.name,
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
        // Wait for the next D-Bus command. In daemon mode we BLOCK on the channel
        // (with a 100ms cap so HID events still get serviced) instead of
        // busy-polling + sleeping — so an unmute from the panel/CLI wakes us
        // instantly (~16ms resume) rather than waiting out a poll interval. The
        // channel is the portable seam: any platform IPC feeds it, and this loop
        // never has to know about D-Bus specifically. In interactive mode the
        // keyboard poll below sets the cadence, so we just drain non-blocking.
        if !is_interactive {
            match commands_rx.recv_timeout(std::time::Duration::from_millis(100)) {
                Ok(command) => apply_command(
                    command,
                    &mut state,
                    &mut device,
                    &mut daemon,
                    &mut processing_linked,
                )?,
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                // D-Bus unavailable (registration failed): no commands will ever
                // arrive, so recv returns instantly — sleep to avoid busy-spin
                // while HID-driven mute still works via device.read() below.
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }
        // Drain any further queued commands (and all of them in interactive mode).
        while let Ok(command) = commands_rx.try_recv() {
            apply_command(
                command,
                &mut state,
                &mut device,
                &mut daemon,
                &mut processing_linked,
            )?;
            // Don't let a burst of queued commands (each sleeping 50ms in the HID
            // pulse) delay shutdown.
            if !running.load(Ordering::SeqCst) {
                break;
            }
        }

        // Backstop reconcile for mute changes that don't go through
        // `apply_command` (keyboard 'm', host-driven HID mute below), and a
        // retry for any gate that previously failed to apply. The D-Bus path
        // already relinked above, so this only acts on a real divergence.
        reconcile_link(
            &daemon.source.name,
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
                    press_mute(&mut device)?;
                    daemon.publish(&state);
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
                            state.in_call = hook;
                            daemon.publish(&state);

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
                            apply_report_command(
                                data[1],
                                "OUTPUT",
                                &mut state,
                                &mut device,
                                &daemon,
                            )?;
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
                            apply_report_command(
                                data[1],
                                "FEATURE",
                                &mut state,
                                &mut device,
                                &daemon,
                            )?;
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
                    // The call app let go of the headset: no call any more.
                    OutputEvent::Stop | OutputEvent::Close => {
                        if state.in_call {
                            state.in_call = false;
                            daemon.publish(&state);
                        }
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

    if let Some(mut child) = meter.lock().unwrap().take() {
        let _ = child.kill();
    }

    // Stop the virtual mic
    if let Err(e) = loopback_process.kill() {
        eprintln!("Warning: Failed to stop the virtual microphone: {}", e);
    } else {
        println!("✓ Stopped the virtual microphone");
    }

    Ok(())
}

/// A control command from HID report 3 (`virtual-headset-ctl mute` and
/// friends): 0x01 mute, 0x02 unmute, 0x03 toggle. Presses the mute button for
/// the call app when it changes something.
fn apply_report_command(
    command: u8,
    kind: &str,
    state: &mut DeviceState,
    device: &mut UHIDDevice<File>,
    daemon: &Daemon,
) -> Result<(), Box<dyn std::error::Error>> {
    let name = match command {
        0x01 if !state.muted => "mute",
        0x02 if state.muted => "unmute",
        0x03 => "toggle",
        _ => return Ok(()),
    };
    state.toggle_mute();
    print_msg!(daemon.is_interactive, "← {}: {} command", kind, name);
    press_mute(device)?;
    daemon.publish(state);
    Ok(())
}
