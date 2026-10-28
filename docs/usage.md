# Using it

Day to day, you'll do three things: pick **Virtual_Headset_Microphone** in your
call app, connect **Virtual_Headset** once in Zoom, and press mute. The rest of
this page is the reference for scripting it.

- [In your call](#in-your-call)
- [Mute](#mute)
- [Linux: virtual-headset-ctl](#linux-virtual-headset-ctl)
- [Linux: D-Bus](#d-bus)
- [Linux: HID reports](#hid-reports)
- [macOS](#macos)

## In your call

1. Choose **Virtual_Headset_Microphone** as your microphone.
2. **Zoom:** open **Settings → Audio** and turn on **Sync buttons on headset**.
   In the browser, Zoom asks to connect a HID device: pick **Virtual_Headset**.
   Zoom only pairs the headset with a mic whose name contains its name, which is
   why the mic must be Virtual_Headset_Microphone.
3. **Google Meet** pairs with the headset whatever mic you choose.
4. **Firefox** can't talk to headsets at all; use [the extension](browser-extension.md).

## Mute

<!-- diagram:mute-loop -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/mute-loop-dark.svg">
  <img src="diagrams/mute-loop.svg" alt="Mute from anywhere, and everything agrees. 1: you press mute with a key, your menu or status bar, a panel or the browser. 2: Virtual Headset presses its mute button, and Zoom or Meet mutes itself as for a real headset. 3: the call app lights the headset's mute light. 4: your controls show muted. Mute inside Zoom or Meet instead, and it starts at 3">
</picture>
<!-- /diagram:mute-loop -->

A mute press is a headset's button press, so the call app decides what it
means: if you're live it mutes, if you're muted it unmutes. On Linux, Virtual
Headset starts **muted** after login.

**Push to talk** (Linux): bind `virtual-headset-ctl ptt-press` to a key's press
and `ptt-release` to its release. Hold the key to talk; tap it (under 300 ms) to
stay unmuted until the next press.

## Linux: virtual-headset-ctl

| Command                                        |                                                            |
| ---------------------------------------------- | ---------------------------------------------------------- |
| `toggle-mute`, `mute`, `unmute`                | press the mute button (through the headset: most reliable) |
| `toggle-mute-dbus`, `mute-dbus`, `unmute-dbus` | the same, through D-Bus                                    |
| `ptt-press`, `ptt-release`                     | push to talk: hold to talk, tap to latch                   |
| `get-source`                                   | the mic being forwarded                                    |
| `list-sources`                                 | the mics you can forward, as JSON                          |
| `set-source <name>`                            | forward that mic (restarts the service: the mic blips)     |
| `clear-source`                                 | follow the system's default mic again                      |
| `monitor-mute`                                 | stream mute changes as JSON, for status bars               |
| `restart-service`                              | restart the user service                                   |
| `find-device`                                  | print the headset's `/dev/hidraw*` path                    |

## D-Bus

The daemon serves `com.github.virtual_headset` at `/com/github/virtual_headset`,
interface `com.github.virtual_headset.Mute`:

| Member               |                                      |
| -------------------- | ------------------------------------ |
| `IsMuted() → bool`   | the current state                    |
| `Mute()`, `Unmute()` | change it, if that changes something |
| `Toggle()`           | flip it                              |
| `MuteChanged(bool)`  | signal, sent on every change         |

```sh
dbus-send --session --print-reply --dest=com.github.virtual_headset \
  /com/github/virtual_headset com.github.virtual_headset.Mute.Toggle

dbus-monitor --session \
  "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
```

## HID reports

The headset also takes commands as HID output report 3, written to its
`/dev/hidraw*` device: `03 01` mutes, `03 02` unmutes, `03 03` toggles. This is
what `virtual-headset-ctl` does.

```sh
printf '\x03\x03' > "$(virtual-headset-ctl find-device)"
```

## macOS

The `virtual-headset` command talks to the running app:

| Command                         |                                  |
| ------------------------------- | -------------------------------- |
| `toggle-mute`, `mute`, `unmute` | press the headset's mute button  |
| `panel [x]`                     | open or close the settings panel |

Its state, for menu bars and scripts, is in `~/.cache/virtual-headset`; see
[your menu bar](macos.md#your-menu-bar).
