---
"virtual-headset": minor
---

Add macOS support: one agent forwards your mic (optionally denoised with DeepFilterNet 3 or RNNoise) into a `Virtual_Headset_Microphone` loopback device and presents the `Virtual_Headset` HID telephony headset that Zoom and Meet sync mute with. While the call is muted it releases the real mic, so Bluetooth headsets switch back from hands-free to stereo. See `docs/macos.md`.
