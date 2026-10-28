---
"virtual-headset": minor
---

The Firefox extension now works on macOS. `virtual-headset bridge` is its native-messaging host there, speaking the same protocol as on Linux, and a Zoom or Meet tab in Firefox becomes the call: the menu bar and panel show its mute, the mic is released while it's muted, and your mute key clicks the tab's mic button. Register the host with `services.virtual-headset.firefox = true` (nix-darwin), the Home Manager module, or `install-native-host.sh`.
