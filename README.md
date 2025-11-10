# Virtual Headset

A virtual USB HID telephony headset for Linux that works with Zoom and Google Meet.

## What it does

Creates a virtual USB headset device that:

- **Appears as a physical headset** to Zoom, Google Meet, and other conferencing apps
- **Forwards audio** from your real microphone through PipeWire
- **Sends mute button events** via USB HID telephony protocol
- **Receives LED feedback** from apps (mute/hook/ring indicators)

This allows you to control mute in Zoom/Meet using your keyboard, just like pressing a physical headset's mute button.

## Requirements

- Linux with kernel HID support
- PipeWire audio system
- Rust toolchain (for building)
- `pw-loopback` command (usually in `pipewire` package)
- `pactl` command (usually in `pulseaudio-utils` or `pipewire-pulse` package)

## Building

```bash
cargo build --release
```

The binary will be in `target/release/virtual-headset`.

## Usage

### Basic usage

1. Run the program:

   ```bash
   ./target/release/virtual-headset
   ```

2. Select your real microphone from the list

3. In Zoom/Meet, select **"Virtual_Headset_Microphone"** as your audio input

4. Press **`m`** to toggle mute

### Controls

- **`m`** - Toggle mute (sends HID button event to apps)
- **`q`** or **`Esc`** - Quit and cleanup
- **`Ctrl+C`** - Emergency quit

## D-Bus Integration

The virtual headset exposes its mute state via D-Bus for integration with status bars and other tools.

### D-Bus Interface

- **Service**: `com.github.virtual_headset`
- **Object Path**: `/com/github/virtual_headset`
- **Interface**: `com.github.virtual_headset.Mute`

### Methods

**`IsMuted() -> bool`**

- Query current mute state
- Returns `true` if muted, `false` if unmuted

### Signals

**`MuteChanged(bool muted)`**

- Emitted whenever mute state changes
- `muted`: `true` when muted, `false` when unmuted

### Examples

**Query current mute state:**

```bash
dbus-send --session --print-reply \
  --dest=com.github.virtual_headset \
  /com/github/virtual_headset \
  com.github.virtual_headset.Mute.IsMuted

# Or use the helper script:
./dbus-query-mute.sh
```

**Listen for mute changes:**

```bash
dbus-monitor --session \
  "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"

# Or use the helper script:
./dbus-monitor-mute.sh
```

### Status Bar Integration

**Waybar example:**

```json
{
  "custom/virtual-headset": {
    "exec": "dbus-monitor --session \"type='signal',interface='com.github.virtual_headset.Mute'\" 2>/dev/null | grep -o 'boolean [a-z]*' | while read _ state; do [ \"$state\" = \"true\" ] && echo \"🔇\" || echo \"🔊\"; done",
    "return-type": "json",
    "format": "{}",
    "on-click": "echo toggle mute here"
  }
}
```

**i3status/i3blocks:**

```bash
# Add to your i3blocks config:
[virtual-headset]
command=dbus-send --session --print-reply --dest=com.github.virtual_headset /com/github/virtual_headset com.github.virtual_headset.Mute.IsMuted 2>/dev/null | grep -q "true" && echo "🔇" || echo "🔊"
interval=persist
```

**Polybar:**

```ini
[module/virtual-headset]
type = custom/script
exec = dbus-query-mute.sh && echo "🔇" || echo "🔊"
tail = true
```

## How it works

### Architecture

```
┌─────────────┐
│ Real        │
│ Microphone  │
└──────┬──────┘
       │
       │ PipeWire
       │ pw-loopback
       ▼
┌─────────────────────┐
│ Virtual_Headset_Mic │  ← Apps connect here
│ (PipeWire Source)   │
└─────────────────────┘

┌─────────────────────┐
│ Virtual HID Device  │  ← Apps detect this
│ /dev/hidraw*        │
│ "Virtual_Headset"   │
└─────────────────────┘
       │
       │ USB HID Telephony Protocol
       │ (Mute button + LED feedback)
       ▼
┌─────────────────────┐
│ Zoom / Google Meet  │
└─────────────────────┘
```

### Technical details

1. **HID Device**: Creates a virtual USB HID Telephony Headset via `/dev/uhid`
   - Vendor ID: `0x0b0e` (Jabra) - triggers kernel telephony driver
   - Product ID: `0x245e` (Jabra Evolve2 65)
   - Device name: `"Virtual_Headset"` - must match audio device name for Zoom

2. **HID Descriptor**: Single Telephony collection with:
   - INPUT Report (ID 1): Hook Switch (bit 0, Absolute) + Phone Mute (bit 1, Relative)
   - OUTPUT Report (ID 2): Mute LED (bit 0) + Off-Hook LED (bit 1) + Ring LED (bit 2)

3. **Audio Routing**: Uses `pw-loopback` to create virtual microphone:

   ```bash
   pw-loopback \
     --capture-props "target.object=<real_mic> node.name=loopback_capture" \
     --playback-props "media.class=Audio/Source node.name=Virtual_Headset_Mic node.description=Virtual_Headset_Microphone"
   ```

4. **Mute Behavior**: Sends HID mute button pulse (0→1→0 transition)
   - Apps detect the Relative toggle and handle muting internally
   - No system-level muting (apps control their own audio processing)

### Why it works with Zoom

Zoom's WebHID code matches devices by checking if the audio device label **includes** the HID device product name:

```javascript
device = devices.find((d) => audioLabel.includes(d.productName));
```

Since our audio device is `"Virtual_Headset_Microphone"` and HID device is `"Virtual_Headset"`, the match succeeds.

## Permissions

The program requires access to:

- `/dev/uhid` - Create virtual HID devices
- `/dev/hidraw*` - Browser WebHID access to the created device

### NixOS

The included NixOS module sets up udev rules automatically:

```nix
# In your configuration.nix
services.uhid = {
  enable = true;
  virtual-headset.enable = true;
};
```

This adds:

- `/dev/uhid` with mode `0660`, group `input`, TAG `uaccess`
- `/dev/hidraw*` matching vendor `0x0b0e` product `0x245e` with mode `0666`

### Other distributions

Add udev rules to `/etc/udev/rules.d/99-uhid.rules`:

```
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"
KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
```

Reload udev:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## Troubleshooting

### Device not showing in Zoom/Meet

1. Check the device was created:

   ```bash
   ls -l /dev/hidraw*
   # Should show device owned by you or mode 0666
   ```

2. Check in browser console (F12):

   ```javascript
   navigator.hid.getDevices();
   // Should show "Virtual_Headset" if previously authorized
   ```

3. Check audio device name matches:
   ```bash
   pactl list sources | grep -A5 Virtual_Headset
   ```

### Mute not working

1. Check HID events are being sent:

   ```bash
   sudo evtest
   # Select the Virtual_Headset device
   # Press 'm' - should see KEY_MICMUTE events
   ```

2. Check Zoom connected to the device:
   - Look for "Device opened by host" message in terminal
   - Should see "Host LEDs" messages when you mute/unmute in Zoom

### Permission denied errors

- Make sure you're in the `input` group: `groups | grep input`
- Check udev rules are loaded: `udevadm info /dev/uhid`
- Restart after adding udev rules

## Project structure

```
virtual-headset/
├── src/
│   ├── main.rs              # Main program logic
│   ├── hid_descriptor.rs    # HID telephony descriptor
│   └── pipewire.rs          # Audio routing via PipeWire
├── Cargo.toml               # Rust dependencies
├── devenv.nix              # Development environment
└── README.md               # This file
```

## Credits

- HID descriptor based on [NicoHood/HID](https://github.com/NicoHood/HID) Arduino library
- Inspired by [gvalkov/python-evdev](https://github.com/gvalkov/python-evdev) for HID event handling
- Uses [uhid-virt](https://crates.io/crates/uhid-virt) for virtual HID device creation

## License

MIT License - See source files for details
