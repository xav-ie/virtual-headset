# Virtual Headset

A virtual USB HID telephony headset for Linux that works with Zoom and Google Meet.

## What it does

Creates a virtual USB headset device that:

- **Appears as a physical headset** to Zoom, Google Meet, and other conferencing apps
- **Forwards audio** from your real microphone through PipeWire
- **Sends mute button events** via USB HID telephony protocol
- **Receives LED feedback** from apps (mute/hook/ring indicators)

This allows you to control mute in Zoom/Meet using your keyboard, just like pressing a physical headset's mute button.

## Installation

### NixOS / Home Manager (Recommended)

This project provides NixOS and Home Manager modules for easy integration.

#### NixOS Module

Add to your `flake.nix`:

```nix
{
  inputs.virtual-headset.url = "github:yourusername/virtual-headset";

  outputs = { self, nixpkgs, virtual-headset, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        virtual-headset.nixosModules.default
        {
          services.virtual-headset = {
            enable = true;
            user = "yourusername";
          };
        }
      ];
    };
  };
}
```

This automatically:

- Sets up udev rules for `/dev/uhid` and `/dev/hidraw*`
- Creates a systemd user service
- Adds the package to your environment

#### Home Manager Module (Waybar Integration)

```nix
{
  imports = [ virtual-headset.homeManagerModules.default ];

  programs.virtual-headset-waybar = {
    enable = true;
    mutedIcon = " ";      # Nerd Font icon for muted
    unmutedIcon = " ";    # Nerd Font icon for unmuted
  };
}
```

This adds a Waybar module that:

- Displays real-time mute status with configurable icons
- Shows initial state on launch
- Updates instantly when mute state changes
- Integrates with your existing Waybar configuration

### Building from source

```bash
# Using Nix flakes
nix build

# Or with Cargo
cargo build --release --manifest-path packages/virtual-headset/Cargo.toml
```

## Requirements

- Linux with kernel HID support
- PipeWire audio system
- `pw-loopback` command (usually in `pipewire` package)
- `pactl` command (usually in `pulseaudio-utils` or `pipewire-pulse` package)

## Usage

### With systemd (NixOS)

The service starts automatically when you log in. Control it with:

```bash
systemctl --user status virtual-headset
systemctl --user restart virtual-headset
```

### Manual execution

1. Run the program:

   ```bash
   virtual-headset
   # Or if built with cargo:
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

**`Toggle()`**

- Toggle the mute state
- Sends HID button event to connected apps

### Signals

**`MuteChanged(bool muted)`**

- Emitted whenever mute state changes
- `muted`: `true` when muted, `false` when unmuted

### Utility Packages

This project includes several Nushell-based utilities for D-Bus interaction:

- **`dbus-monitor-mute`** - Monitor mute state changes with JSON output for Waybar
- **`dbus-query-mute`** - Query current mute state (exit code: 0=muted, 1=unmuted)
- **`dbus-toggle-mute`** - Toggle mute state via D-Bus
- **`systemd-restart-virtual-headset`** - Restart the systemd service

### Examples

**Query current mute state:**

```bash
# Using the utility package
dbus-query-mute

# Or directly with dbus-send
dbus-send --session --print-reply \
  --dest=com.github.virtual_headset \
  /com/github/virtual_headset \
  com.github.virtual_headset.Mute.IsMuted
```

**Toggle mute:**

```bash
# Using the utility package
dbus-toggle-mute

# Or directly with dbus-send
dbus-send --session --print-reply \
  --dest=com.github.virtual_headset \
  /com/github/virtual_headset \
  com.github.virtual_headset.Mute.Toggle
```

**Monitor for changes:**

```bash
# Using the utility package (outputs JSON for Waybar)
dbus-monitor-mute

# Or directly with dbus-monitor
dbus-monitor --session \
  "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
```

### Status Bar Integration

For Waybar integration, see the [Home Manager Module](#home-manager-module-waybar-integration) section above.

For other status bars, you can use the utility packages:

**i3status/i3blocks:**

```bash
# Add to your i3blocks config:
[virtual-headset]
command=dbus-query-mute && echo "🔇" || echo "🔊"
interval=1
```

**Polybar:**

```ini
[module/virtual-headset]
type = custom/script
exec = dbus-query-mute && echo "🔇" || echo "🔊"
interval = 1
click-left = dbus-toggle-mute
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
services.virtual-headset = {
  enable = true;
  user = "yourusername";
};
```

This adds:

- `/dev/uhid` with mode `0660`, group `input`, TAG `uaccess`
- `/dev/hidraw*` matching vendor `0x0b0e` product `0x245e` with mode `0666`, TAG `uaccess`
- User added to the `input` group

### Other distributions

Add udev rules to `/etc/udev/rules.d/99-virtual-headset.rules`:

```
# Allow access to /dev/uhid for creating virtual HID devices
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

# Allow browser WebHID access to virtual headset device
# Matches Jabra vendor (0x0b0e) product (0x245e)
KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
```

Add your user to the `input` group:

```bash
sudo usermod -aG input $USER
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
├── packages/
│   ├── virtual-headset/           # Main Rust application
│   │   ├── src/
│   │   │   ├── main.rs            # Main program logic
│   │   │   ├── hid_descriptor.rs  # HID telephony descriptor
│   │   │   ├── dbus_interface.rs  # D-Bus service implementation
│   │   │   └── pipewire.rs        # Audio routing via PipeWire
│   │   ├── Cargo.toml
│   │   └── default.nix            # Nix package definition
│   ├── dbus-monitor-mute/         # Waybar-compatible mute monitor
│   │   └── dbus-monitor-mute.nu
│   ├── dbus-query-mute/           # Query mute state
│   │   └── dbus-query-mute.nu
│   ├── dbus-toggle-mute/          # Toggle mute via D-Bus
│   │   └── dbus-toggle-mute.nu
│   └── systemd-restart-virtual-headset/  # Service restart utility
│       └── systemd-restart-virtual-headset.nu
├── flake.nix                      # Nix flake with modules
├── justfile                       # Build commands
└── README.md                      # This file
```

## Development

### Building and testing

```bash
# Check flake and build all packages
just check

# Build the default package
just build

# Run the virtual headset
just run

# Show flake outputs
just show
```

### Development shell

```bash
nix develop
```

This provides:

- Rust toolchain (cargo, rustc, rust-analyzer, clippy, rustfmt)
- Required system libraries
- Code formatting tools (treefmt)

### Code formatting

```bash
treefmt
```

Formats:

- Rust code (rustfmt)
- Nix code (nixfmt)
- TOML files (taplo)
- Markdown and other files (prettier)

## Credits

- HID descriptor based on [NicoHood/HID](https://github.com/NicoHood/HID) Arduino library
- Inspired by [gvalkov/python-evdev](https://github.com/gvalkov/python-evdev) for HID event handling
- Uses [uhid-virt](https://crates.io/crates/uhid-virt) for virtual HID device creation
- Built with [Nix](https://nixos.org/) and [flake-parts](https://flake.parts/)

## License

MIT License - See source files for details
