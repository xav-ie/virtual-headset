# 🎧 Virtual Headset

[![CI](https://github.com/xav-ie/virtual-headset/actions/workflows/ci.yml/badge.svg)](https://github.com/xav-ie/virtual-headset/actions/workflows/ci.yml)

**A software mute button for any microphone on Linux — that Zoom and Google Meet actually respect.**

Your mic probably doesn't have a mute button. Virtual Headset gives it one:
press a key (or click your status bar, or your browser toolbar) and your call
mutes — and when you mute inside Zoom or Meet, everything else follows. It works
because the call apps see a real telephony headset, not a script poking at them.

<!-- TODO: drop a short screen recording / screenshot here (panel + bar + browser icon) -->

## Features

- **Mute button for any mic** — no special hardware; use the microphone you already have.
- **Speaks Zoom & Meet's language** — appears as a real USB telephony headset, so their own mute button stays in sync with yours, both ways.
- **Mute from anywhere** — a keyboard shortcut, a click in your status bar, your browser toolbar, or D-Bus.
- **Works in Firefox too** — a small extension bridges the web apps (Firefox has no WebHID), so mute syncs in the browser as well as the desktop client.
- **Pick which mic to use** — choose the forwarded source from a desktop panel, the browser menu, or the CLI.
- **Safe by default** — starts muted, so you're never accidentally live right after login.
- **Status-bar ready** — Waybar, i3, Polybar, plus a built-in desktop panel.
- **First-class NixOS** — NixOS & Home Manager modules included (and it runs on any distro).

## How it works

Virtual Headset creates two things:

1. a **virtual microphone** that forwards your real mic through PipeWire, and
2. a **virtual USB telephony headset** that Zoom and Google Meet recognize.

Because conferencing apps trust headset mute buttons, you can now mute from your
keyboard, status bar, or browser — and because the connection is two-way, muting
inside the app updates your indicators too. The actual audio is muted by the app
(just like a real headset), so there's nothing system-wide to clean up.

→ Full details in [docs/architecture.md](./docs/architecture.md).

## Quick start (NixOS)

```nix
{
  inputs.virtual-headset.url = "github:xav-ie/virtual-headset";

  # in your NixOS configuration:
  imports = [ inputs.virtual-headset.nixosModules.default ];
  services.virtual-headset.enable = true;
}
```

That's it — the service starts at login (muted), creates
`Virtual_Headset_Microphone`, and sets up device permissions. In Zoom/Meet,
choose **Virtual_Headset_Microphone** as your input.

Not on Nix, or want the Home Manager / Waybar / browser pieces? See the
[installation guide](./docs/installation.md).

## Control it from anywhere

| Where             | How                                                                               |
| ----------------- | --------------------------------------------------------------------------------- |
| **Keyboard**      | Bind a key to `virtual-headset-ctl toggle-mute`                                   |
| **Status bar**    | [Waybar / i3 / Polybar modules](./docs/status-bar.md)                             |
| **Desktop panel** | A built-in [AGS panel](./docs/status-bar.md#desktop-panel) — mute + source picker |
| **Browser**       | A [Firefox extension](./docs/browser-extension.md) — toolbar mute + source menu   |
| **Scripts**       | `virtual-headset-ctl` or the [D-Bus interface](./docs/usage.md#d-bus-interface)   |

## Documentation

- [Installation](./docs/installation.md) — Nix modules, building from source, requirements, device permissions
- [Usage & control](./docs/usage.md) — `virtual-headset-ctl`, D-Bus, and HID reference
- [Browser extension](./docs/browser-extension.md) — Firefox bridge for Zoom/Meet web apps
- [Status bar & desktop panel](./docs/status-bar.md) — Waybar/i3/Polybar and the AGS panel
- [How it works](./docs/architecture.md) — architecture and the technical details
- [Troubleshooting](./docs/troubleshooting.md)
- [Development](./docs/development.md)

## Requirements

- Linux with kernel HID support (standard since 2012)
- PipeWire

The Nix package bundles the rest. Without Nix you'll also need `pw-loopback`
(pipewire) and `pactl` (pipewire-pulse / pulseaudio-utils) — see
[installation](./docs/installation.md).

## Credits

Built on the shoulders of these excellent resources:

- [Make your first steps with a USB HID Report](https://www.noser.com/techblog/first-steps-with-an-usb-hid-report/)
- [Introduction to HID report descriptors](https://www.kernel.org/doc/html/latest/hid/hidintro.html)
- [UHID — User-space I/O driver support for HID](https://www.kernel.org/doc/html/latest/hid/uhid.html)
- [uhid-virt](https://crates.io/crates/uhid-virt) for virtual HID device creation

## License

[MIT](./LICENSE.md)
