# Installation

- [NixOS](#nixos) (recommended)
- [Home Manager](#home-manager)
- [Building from source](#building-from-source)
- [Requirements](#requirements)
- [Device permissions](#device-permissions) (non-NixOS)

## NixOS

Add the flake input and enable the module:

```nix
{
  inputs.virtual-headset.url = "github:xav-ie/virtual-headset";

  # in your NixOS configuration:
  imports = [ inputs.virtual-headset.nixosModules.default ];
  services.virtual-headset.enable = true;
}
```

The module installs the daemon, sets up the udev rules and `input` group
membership, and runs `virtual-headset` as a user service that starts at login.
See [nixosModules/default.nix](../nixosModules/default.nix) for all options.

## Home Manager

Two optional Home Manager modules add desktop integration:

```nix
{
  imports = [
    virtual-headset.homeManagerModules.default # Waybar mute indicator
    virtual-headset.homeManagerModules.firefox # Firefox bridge native host
  ];

  programs.virtual-headset-waybar.enable = true;
  programs.virtual-headset-firefox.enable = true;
}
```

- `homeManagerModules.default` — a Waybar module showing/toggling mute. See
  [Status bar & desktop panel](./status-bar.md).
- `homeManagerModules.firefox` — registers the browser native-messaging host.
  See [Browser extension](./browser-extension.md).

## Building from source

```bash
# Using Nix flakes
just build      # or: nix build

# Or with Cargo
cargo build --release --manifest-path packages/virtual-headset/Cargo.toml
```

## Requirements

- Linux with kernel HID support (standard since 2012)
- PipeWire

If you're **not** using the Nix integration, also make sure you have:

- `pw-loopback` (usually in the `pipewire` package)
- `pactl` (usually in `pulseaudio-utils` or `pipewire-pulse`)

The Nix package bundles these automatically.

## Device permissions

The program needs access to:

- `/dev/uhid` — to create the virtual HID device
- `/dev/hidraw*` — for control (and Chromium's WebHID) access to it

On **NixOS** the module handles this for you. On **other distributions**, add
udev rules at `/etc/udev/rules.d/99-virtual-headset.rules`:

```
# Allow access to /dev/uhid for creating virtual HID devices
KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

# Allow browser WebHID access to the virtual headset device
# Matches Jabra vendor (0x0b0e) product (0x245e)
KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
```

Add your user to the `input` group:

```bash
sudo usermod -aG input $USER
```

Reload udev (and log out/in for the group change):

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```
