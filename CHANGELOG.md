# virtual-headset

## 0.3.0

### Minor Changes

- fbb1324: Suspend the denoiser while muted. On mute, the daemon unlinks the source from the
  loopback capture (`pw-link -d`), so the RNNoise filter and raw mic lose their
  consumer and suspend to ~0% CPU; the loopback keeps feeding silence into
  `Virtual_Headset_Mic`, so the device stays present for the call app. Unmuting
  relinks it and the mic resumes in ~16ms (inaudible). This reclaims the ~2-3% the
  denoiser otherwise burned during the muted portions of a call (on top of the
  passive-loopback change that already idles the chain when no app is capturing).
- 42a93bd: Make the virtual mic suspend when idle. The `pw-loopback` capture is now
  `node.passive=true`, so the loopback — and the upstream RNNoise denoiser and raw
  mic it pulls from — only run while an application is actually capturing
  `Virtual_Headset_Mic`. Previously the loopback pulled continuously and pinned the
  denoiser at ~2–3% CPU 24/7, even while idle/muted. The chain now sits at ~0% and
  wakes instantly when Zoom/Meet opens the device.

### Patch Changes

- 8ac8b59: Harden the mute audio-gate (from code review):

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

- 4450058: Make unmute near-instant (~16ms, was ~110ms). Two changes: the event loop now
  blocks on the toggle channel (`recv_timeout`) instead of busy-polling with a
  100ms sleep, so a mute/unmute from the panel/CLI is handled on arrival; and the
  audio relink now happens before the 50ms HID button pulse, so the denoised mic
  returns immediately rather than waiting out the host-notification pulse. HID
  events still get a 100ms fallback tick, and the daemon still runs if D-Bus
  registration fails.

## 0.2.1

### Patch Changes

- ddc1003: Automate releases with changesets: a "version packages" PR bumps the version and
  CHANGELOG, and merging it tags `v<version>` to sign and publish the extension.
