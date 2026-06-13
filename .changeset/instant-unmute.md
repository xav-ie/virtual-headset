---
"virtual-headset": patch
---

Make unmute near-instant (~16ms, was ~110ms). Two changes: the event loop now
blocks on the toggle channel (`recv_timeout`) instead of busy-polling with a
100ms sleep, so a mute/unmute from the panel/CLI is handled on arrival; and the
audio relink now happens before the 50ms HID button pulse, so the denoised mic
returns immediately rather than waiting out the host-notification pulse. HID
events still get a 100ms fallback tick, and the daemon still runs if D-Bus
registration fails.
