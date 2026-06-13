---
"virtual-headset": patch
---

Harden the mute audio-gate (from code review):

- Fix a startup race where the muted-by-default cut could run before wireplumber
  created the loopback's auto-link, leaving the denoise chain wired while muted
  with no later reconcile to correct it. The daemon now waits (bounded) for the
  link to exist before asserting the initial cut.
- `set_capture_linked` now reports whether the gate actually ran, and the
  reconcile only advances its tracked state on success — so a transient
  pw-link/PipeWire failure is retried on the next loop instead of being silently
  assumed applied.
- The toggle-drain loop now checks the shutdown flag, so a burst of queued
  toggles (each with a 50ms HID pulse) can't delay exit.
