# Installation

- **Linux:** [NixOS](#nixos), [Home Manager extras](#home-manager-extras), or
  [without Nix](#without-nix)
- **macOS:** [nix-darwin](#macos)

## NixOS

```nix
{
  inputs.virtual-headset.url = "github:xav-ie/virtual-headset";

  # in your NixOS configuration
  imports = [ inputs.virtual-headset.nixosModules.default ];
  services.virtual-headset = {
    enable = true;
    user = "you"; # gets access to the virtual device
  };
}
```

This installs Virtual Headset, gives your user access to the virtual device, and
runs it at login, **muted**. It forwards your default mic; to forward a different
one, pick it from the [panel](status-bar.md#desktop-panel), the
[Firefox extension](browser-extension.md) or `virtual-headset-ctl set-source`. All
options are in [nixosModules/default.nix](../nixosModules/default.nix).

## Home Manager extras

Two optional Home Manager modules add a Waybar indicator and the Firefox
extension:

```nix
{
  imports = [
    inputs.virtual-headset.homeManagerModules.default # Waybar
    inputs.virtual-headset.homeManagerModules.firefox # Firefox
  ];

  programs.virtual-headset-waybar.enable = true;
  programs.virtual-headset-firefox = {
    enable = true;
    # Install the signed extension from the latest release, kept up to date.
    # Needs programs.firefox; leave it out to load the extension yourself.
    installExtension = true;
  };
}
```

See [status bars](status-bar.md#waybar) and [Firefox](browser-extension.md) for
what they do.

## Without Nix

You need PipeWire, with `pw-loopback` (from `pipewire`) and `pactl` (from
`pipewire-pulse` or `pulseaudio-utils`).

1. **Build it.**

   ```sh
   cargo build --release --manifest-path packages/virtual-headset/Cargo.toml
   ```

2. **Allow access to the virtual device.** Save this as
   `/etc/udev/rules.d/99-virtual-headset.rules`:

   ```
   # Create virtual HID devices
   KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

   # Let browsers (WebHID) and virtual-headset-ctl reach the headset
   KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
   ```

   Then add yourself to the `input` group, reload the rules, and log out and back
   in:

   ```sh
   sudo usermod -aG input "$USER"
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

3. **Run it.** `./target/release/virtual-headset` asks which mic to forward, then
   `m` toggles mute and `q` quits. Run as a service (no terminal), it forwards
   your default mic.

## macOS

```nix
{
  inputs.virtual-headset.url = "github:xav-ie/virtual-headset";

  # in your nix-darwin configuration
  imports = [ inputs.virtual-headset.darwinModules.default ];
  services.virtual-headset.enable = true;
}
```

macOS needs a boot argument first, and installing without nix-darwin takes a few
manual steps: see [macOS](macos.md#install).
