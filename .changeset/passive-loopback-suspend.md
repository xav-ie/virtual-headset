---
"virtual-headset": minor
---

Make the virtual mic suspend when idle. The `pw-loopback` capture is now
`node.passive=true`, so the loopback — and the upstream RNNoise denoiser and raw
mic it pulls from — only run while an application is actually capturing
`Virtual_Headset_Mic`. Previously the loopback pulled continuously and pinned the
denoiser at ~2–3% CPU 24/7, even while idle/muted. The chain now sits at ~0% and
wakes instantly when Zoom/Meet opens the device.
