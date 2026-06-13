---
"virtual-headset": patch
---

Make unmute wake the daemon instantly. The event loop now blocks on the toggle
channel (`recv_timeout`) instead of busy-polling with a 100ms sleep, so a
mute/unmute from the panel/CLI is applied on arrival (~16ms audio resume) rather
than waiting out a poll interval (~100ms before). HID events still get serviced
on a 100ms fallback tick, and the daemon still runs if D-Bus registration fails.
