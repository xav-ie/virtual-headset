# Virtual HID Telephony Device for Zoom/Teams Integration

## Project Overview

### Architecture

```
┌─────────────────┐
│   Real Mic      │
│  (Hardware)     │
└────────┬────────┘
         │
         v
┌─────────────────────────┐
│  PipeWire Virtual Sink  │
│   (Audio Passthrough)   │
└────────┬────────────────┘
         │
         v
┌─────────────────────────┐
│  Zoom / Teams / Apps    │◄──────┐
│  (Sees virtual headset) │       │
└─────────────────────────┘       │
                                  │
                          HID Mute Button
                                  │
┌─────────────────────────┐       │
│  Virtual HID Telephony  │───────┘
│  Device (UHID Driver)   │
└────────┬────────────────┘
         │
         v
┌─────────────────────────┐
│   System Tray UI        │
│   (Mute Indicator)      │
└─────────────────────────┘
```

### Goals

1. **Virtual HID telephony device** that apps recognize as a headset with mute button
2. **PipeWire virtual audio device** that forwards from your real microphone
3. **Bidirectional communication**: Send mute button presses, receive LED feedback
4. **System tray integration**: Visual mute state indicator

### Why This Approach?

- Your real mic has no hardware mute button
- Apps like Zoom prefer HID telephony devices for mute control
- Virtual audio device allows apps to mute programmatically
- Clean separation: HID provides control, PipeWire provides audio

---

## Phase 1: Basic HID Telephony Device

**Goal:** Create a virtual HID device that Zoom recognizes as a headset

### 1.1 System Setup

#### Grant UHID Access

```bash
# Create udev rule for UHID device access
sudo tee /etc/udev/rules.d/99-uhid.rules <<EOF
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"
EOF

# Reload udev rules
sudo udevadm control --reload-rules

# Add yourself to input group
sudo usermod -a -G input $USER

# Log out and back in for group changes to take effect
```

#### Verify Access

```bash
# Should be readable/writable by your user
ls -l /dev/uhid

# Should show input group membership
groups
```

### 1.2 Project Setup

```bash
cargo new virtual-headset
cd virtual-headset
```

#### Cargo.toml

```toml
[package]
name = "virtual-headset"
version = "0.1.0"
edition = "2021"

[dependencies]
uhid-virt = "0.0.8"
arrayvec = "0.7"
```

### 1.3 HID Descriptor Design

Based on the [Noser HID article](https://www.noser.com/techblog/first-steps-with-an-usb-hid-report/), we need:

- **Usage Page 0x0B (Telephony Devices)**
- **Input Report**: Mute button state (device → host)
- **Output Report**: LED state (host → device)

#### Understanding HID Descriptors

From the Noser article:

> "Descriptors use paired bytes where the first byte indicates the data type and the second contains the value."

For example:

- `0x05, 0x0B` = Usage Page (0x05) for Telephony (0x0B)
- `0x09, 0x2F` = Usage (0x09) for Phone Mute (0x2F)
- `0x81, 0x02` = Input report (Data, Variable, Absolute)
- `0x91, 0x02` = Output report (Data, Variable, Absolute)

#### HID Report Descriptor

```rust
// src/hid_descriptor.rs
pub const TELEPHONY_DESCRIPTOR: [u8; 54] = [
    0x05, 0x0B,        // Usage Page (Telephony)
    0x09, 0x05,        // Usage (Headset)
    0xA1, 0x01,        // Collection (Application)

    // Input Report - Mute Button
    0x85, 0x01,        //   Report ID (1)
    0x05, 0x0B,        //   Usage Page (Telephony)
    0x09, 0x2F,        //   Usage (Phone Mute)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1 bit)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Padding for byte alignment
    0x75, 0x07,        //   Report Size (7 bits)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x03,        //   Input (Const,Var,Abs) - padding

    // Output Report - Mute LED
    0x85, 0x02,        //   Report ID (2)
    0x05, 0x08,        //   Usage Page (LEDs)
    0x09, 0x09,        //   Usage (Mute LED)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1 bit)
    0x95, 0x01,        //   Report Count (1)
    0x91, 0x02,        //   Output (Data,Var,Abs)

    // Padding for byte alignment
    0x75, 0x07,        //   Report Size (7 bits)
    0x95, 0x01,        //   Report Count (1)
    0x91, 0x03,        //   Output (Const,Var,Abs) - padding

    0xC0,              // End Collection
];
```

### 1.4 Basic Implementation

Based on the gearvr-controller-uhid example:

```rust
// src/main.rs
use arrayvec::ArrayVec;
use uhid_virt::{Bus, CreateParams, UHIDDevice};
use std::fs::File;

mod hid_descriptor;
use hid_descriptor::TELEPHONY_DESCRIPTOR;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Creating virtual HID telephony device...");

    // Create HID device parameters
    let mut rd_data = ArrayVec::new();
    rd_data.try_extend_from_slice(&TELEPHONY_DESCRIPTOR)?;

    let params = CreateParams {
        name: "Virtual Zoom Headset".to_string(),
        phys: String::new(),
        uniq: String::new(),
        bus: Bus::USB,
        vendor: 0x1234,  // Dummy vendor ID
        product: 0x5678, // Dummy product ID
        version: 1,
        country: 0,
        rd_data,
    };

    let device = UHIDDevice::<File>::create(params)?;
    println!("Device created successfully!");
    println!("Check /dev/hidraw* for the new device");

    // Send a mute button press
    println!("Sending mute button press...");
    let mute_press = [0x01, 0x01]; // Report ID 1, mute bit = 1
    device.write_input(&mute_press)?;

    std::thread::sleep(std::time::Duration::from_millis(100));

    // Send mute button release
    println!("Sending mute button release...");
    let mute_release = [0x01, 0x00]; // Report ID 1, mute bit = 0
    device.write_input(&mute_release)?;

    println!("Press Ctrl+C to exit");
    loop {
        std::thread::sleep(std::time::Duration::from_secs(1));
    }
}
```

### 1.5 Testing

#### List HID Devices

```bash
# Find your virtual device
ls -l /dev/hidraw*

# Check device info
cat /sys/class/hidraw/hidraw*/device/uevent
```

#### Test with evtest

```bash
# Install evtest
sudo pacman -S evtest  # or your package manager

# Find the device
sudo evtest

# Select your virtual headset and watch for events
```

#### Test with Zoom

1. Open Zoom settings → Audio
2. Enable "Sync buttons on headset"
3. Look for your device in the list
4. Press the mute button in your app - LED feedback should appear

---

## Phase 2: Bidirectional Communication

**Goal:** Read LED feedback from apps when they change mute state

### 2.1 Event Loop Architecture

```rust
// src/main.rs
use uhid_virt::{OutputEvent, StreamError};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, Debug)]
struct MuteState {
    button_pressed: bool,
    led_on: bool,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let device = create_device()?;
    let state = Arc::new(Mutex::new(MuteState {
        button_pressed: false,
        led_on: false,
    }));

    println!("Entering event loop...");
    loop {
        // Read events from UHID
        match device.read_event() {
            Ok(event) => handle_event(event, &device, state.clone())?,
            Err(StreamError::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(e) => return Err(e.into()),
        }
    }
}

fn handle_event(
    event: uhid_virt::UHIDEvent,
    device: &UHIDDevice<File>,
    state: Arc<Mutex<MuteState>>,
) -> Result<(), Box<dyn std::error::Error>> {
    match event {
        uhid_virt::UHIDEvent::Output { data } => {
            // App (e.g., Zoom) is updating our LED
            if data.len() >= 2 && data[0] == 0x02 {
                // Report ID 2 = LED output
                let led_state = data[1] & 0x01 != 0;

                let mut state = state.lock().unwrap();
                state.led_on = led_state;

                println!("LED state changed: {}", if led_state { "ON" } else { "OFF" });
            }
        }
        _ => {}
    }
    Ok(())
}
```

### 2.2 State Management

```rust
// src/state.rs
use std::sync::{Arc, Mutex};

pub struct DeviceState {
    pub muted: bool,
    pub led_on: bool,
}

impl DeviceState {
    pub fn new() -> Arc<Mutex<Self>> {
        Arc::new(Mutex::new(Self {
            muted: false,
            led_on: false,
        }))
    }

    pub fn toggle_mute(&mut self) -> bool {
        self.muted = !self.muted;
        self.muted
    }

    pub fn sync_with_led(&mut self) {
        self.muted = self.led_on;
    }
}
```

### 2.3 Commands

```rust
// src/commands.rs
pub enum Command {
    ToggleMute,
    SetMute(bool),
    GetState,
    Exit,
}

// In main event loop, handle user commands via stdin or D-Bus
```

---

## Phase 3: PipeWire Virtual Audio Device

**Goal:** Create virtual audio sink/source that forwards from real mic

### 3.1 PipeWire Dependencies

```toml
[dependencies]
pipewire = "0.8"
```

### 3.2 Virtual Audio Device

```rust
// src/audio.rs
use pipewire as pw;

pub struct VirtualAudioDevice {
    // PipeWire context and streams
}

impl VirtualAudioDevice {
    pub fn new(real_device_name: &str) -> Result<Self, Box<dyn std::error::Error>> {
        // Initialize PipeWire
        pw::init();

        // Create virtual source that forwards from real mic
        // This makes apps see "Virtual Headset Microphone"
        // instead of your real mic

        todo!("Implement PipeWire virtual device")
    }

    pub fn set_muted(&mut self, muted: bool) {
        // Mute/unmute the virtual device
        // (Apps should handle this via HID, but we can do it programmatically too)
    }
}
```

### 3.3 Integration with HID State

```rust
// When HID mute button is pressed:
// 1. Send HID input report (tell Zoom to mute)
// 2. Zoom sees button press and mutes the virtual audio device
// 3. We receive LED output report from Zoom
// 4. Update system tray to show muted state

// The audio muting is handled by the app (Zoom), not by us!
// We just provide the control interface.
```

---

## Phase 4: System Tray UI

**Goal:** Visual indicator and manual control

### 4.1 Dependencies

```toml
[dependencies]
tray-icon = "0.14"  # System tray
```

### 4.2 Tray Icon

```rust
// src/tray.rs
use tray_icon::{TrayIcon, TrayIconBuilder};

pub struct TrayUI {
    icon: TrayIcon,
}

impl TrayUI {
    pub fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let icon = TrayIconBuilder::new()
            .with_tooltip("Virtual Headset")
            .with_icon_from_buffer(UNMUTED_ICON, (32, 32))
            .build()?;

        Ok(Self { icon })
    }

    pub fn set_muted(&mut self, muted: bool) {
        let icon = if muted { MUTED_ICON } else { UNMUTED_ICON };
        // Update icon
    }
}

// Icon assets (embed in binary)
const MUTED_ICON: &[u8] = include_bytes!("../assets/muted.png");
const UNMUTED_ICON: &[u8] = include_bytes!("../assets/unmuted.png");
```

### 4.3 D-Bus Interface (Optional, for Waybar)

```toml
[dependencies]
zbus = "4.0"
```

```rust
// src/dbus.rs
use zbus::{Connection, interface};

struct MuteInterface {
    state: Arc<Mutex<DeviceState>>,
}

#[interface(name = "com.example.VirtualHeadset")]
impl MuteInterface {
    fn is_muted(&self) -> bool {
        self.state.lock().unwrap().muted
    }

    fn toggle_mute(&mut self) {
        // Toggle and send HID event
    }

    #[signal]
    fn mute_changed(&self, muted: bool) -> zbus::Result<()>;
}
```

---

## Getting Started: Step-by-Step

### Step 1: Minimal Working Example

Start with the simplest possible implementation:

```bash
cargo new virtual-headset
cd virtual-headset
```

Add to `Cargo.toml`:

```toml
[dependencies]
uhid-virt = "0.0.8"
```

Copy the Phase 1.4 code and run:

```bash
cargo run
```

Verify the device appears:

```bash
ls -l /dev/hidraw*
sudo evtest  # Select your device
```

### Step 2: Test with Zoom

1. Open Zoom → Settings → Audio
2. Enable "Sync buttons on headset"
3. Modify your code to send mute button presses on keypress
4. Verify Zoom responds

### Step 3: Add Event Reading

Implement the Phase 2 event loop to read LED feedback.

### Step 4: Add PipeWire (Later)

After HID device works reliably, add virtual audio device.

### Step 5: Add UI (Last)

Finally, add system tray integration.

---

## Project Structure

```
virtual-headset/
├── Cargo.toml
├── src/
│   ├── main.rs           # Entry point and main loop
│   ├── hid_descriptor.rs # HID report descriptor
│   ├── hid_device.rs     # UHID device management
│   ├── state.rs          # Shared state
│   ├── audio.rs          # PipeWire integration (Phase 3)
│   └── tray.rs           # System tray UI (Phase 4)
├── assets/
│   ├── muted.png
│   └── unmuted.png
└── README.md
```

---

## Debugging Tools

### Monitor HID Events

```bash
# Watch kernel logs
sudo dmesg -w | grep -i hid

# Monitor all HID devices
sudo hid-recorder /dev/hidraw0
```

### Parse HID Descriptors

Use [Frank Zhao's HID Descriptor Parser](https://eleccelerator.com/usbdescreqparser/):

- Paste your descriptor bytes
- Verify structure matches expectations

### Test USB Device Info

```bash
lsusb -v | grep -A 20 "Virtual Zoom"
```

---

## Resources

### HID Specification

- [USB HID Usage Tables](https://usb.org/sites/default/files/hut1_4.pdf) - Official usage page definitions
- [Telephony Usage Page](https://usb.org/sites/default/files/hut1_4.pdf#page=118) - Page 0x0B definitions

### Articles and Guides

- [Noser: First Steps with USB HID Report](https://www.noser.com/techblog/first-steps-with-an-usb-hid-report/) - Excellent intro
- [Jan Axelson's USB Complete](https://janaxelson.com/usb.htm) - Comprehensive reference

### Example Projects

- [gearvr-controller-uhid](https://github.com/sameer/gearvr-controller-uhid) - UHID device example
- [uhid-virt docs](https://docs.rs/uhid-virt) - Rust library documentation

### PipeWire

- [PipeWire Documentation](https://docs.pipewire.org/)
- [pipewire-rs](https://gitlab.freedesktop.org/pipewire/pipewire-rs) - Rust bindings

### Tools

- [HID Descriptor Tool](https://www.usb.org/document-library/hid-descriptor-tool) - Windows tool for creating descriptors
- [Frank Zhao's Descriptor Parser](https://eleccelerator.com/usbdescreqparser/) - Online parser
- `evtest` - Linux tool for testing input devices
- `hid-tools` - Python tools for HID debugging

---

## FAQ

### Why not just use a hardware button?

Hardware mute buttons require special hardware. This approach works with any microphone and gives you software control.

### Why both HID and PipeWire?

- **HID**: Provides the control interface apps expect (mute button)
- **PipeWire**: Provides the audio routing apps need (virtual mic)

Apps like Zoom want both: a mute button AND a microphone to mute.

### Can I use this with Teams/Discord/etc?

Yes! Any app that supports HID telephony devices should work. The HID specification is standardized.

### Do I need root access?

Only for initial udev setup. After that, normal user access works.

---

## Next Steps

1. **Start with Phase 1**: Get the basic HID device working
2. **Test with Zoom**: Verify recognition and mute button
3. **Add event loop**: Implement Phase 2 for bidirectional communication
4. **Iterate**: Add features incrementally

Good luck! 🎧
