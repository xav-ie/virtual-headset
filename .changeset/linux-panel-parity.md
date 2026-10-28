---
default: minor
---

# Linux panel like the Mac, and noise suppression

Linux catches up with the Mac: optional DeepFilterNet noise suppression (a PipeWire filter-chain in place of the loopback, with live strength), the call's mute state from the headset's off-hook light, a mic level meter, and a "Keep the mic open between calls" setting. The desktop panel is laid out like the macOS one, with keyboard focus rings and screen-reader labels, and `virtual-headset-ctl` gains `state`, `monitor-state`, `monitor-level`, `set-denoise`, `set-strength`, `set-keep-open`, `test-record` and `test-play`.
