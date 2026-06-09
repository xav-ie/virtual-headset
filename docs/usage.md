# Usage & control

The virtual headset can be controlled from the keyboard, a status bar, the
browser, or scripts. Under the hood everything goes through one of three
surfaces: the `virtual-headset-ctl` CLI, the D-Bus interface, or raw HID
reports.

- [Running it](#running-it)
- [Controls (interactive)](#controls-interactive)
- [virtual-headset-ctl](#virtual-headset-ctl)
- [D-Bus interface](#d-bus-interface)
- [HID control](#hid-control)
- [Examples](#examples)

## Running it

### As a service (NixOS)

The service starts automatically at login and comes up **muted**. Control it
with:

```bash
systemctl --user status virtual-headset
systemctl --user restart virtual-headset
```

On a non-interactive start (the service), it forwards your configured source, or
the PipeWire **default** source if none is set. After changing the default
source, restart the service so it picks up the new input — or set a specific one
with `virtual-headset-ctl set-source` (see [Status bar & desktop
panel](./status-bar.md)).

### Manually (interactive)

```bash
virtual-headset
# or, if built with cargo:
./target/release/virtual-headset
```

Then pick your real microphone, and in Zoom/Meet select
**Virtual_Headset_Microphone** as your input.

## Controls (interactive)

- **`m`** — toggle mute (sends the HID button event to apps)
- **`q`** / **`Esc`** — quit and clean up
- **`Ctrl+C`** — emergency quit

## virtual-headset-ctl

The `virtual-headset-ctl` utility provides convenient commands:

| Command                                          | Description                                            |
| ------------------------------------------------ | ------------------------------------------------------ |
| `mute` / `unmute` / `toggle-mute`                | Set mute state (via HID OUTPUT report — most reliable) |
| `mute-dbus` / `unmute-dbus` / `toggle-mute-dbus` | Same, via D-Bus                                        |
| `get-source`                                     | Description of the source currently being forwarded    |
| `list-sources`                                   | Forwardable input sources as JSON (for pickers)        |
| `set-source <name>`                              | Forward a specific source (restarts the service)       |
| `clear-source`                                   | Go back to following the system default source         |
| `monitor-mute`                                   | Stream mute-state changes as JSON (for status bars)    |
| `restart-service`                                | Restart the systemd user service                       |
| `find-device`                                    | Print the hidraw device path                           |

## D-Bus interface

- **Service**: `com.github.virtual_headset`
- **Object path**: `/com/github/virtual_headset`
- **Interface**: `com.github.virtual_headset.Mute`

**Methods**

- `IsMuted() -> bool` — query current mute state
- `Mute()` — mute if not already muted
- `Unmute()` — unmute if currently muted
- `Toggle()` — toggle the mute state

**Signals**

- `MuteChanged(bool muted)` — emitted whenever the mute state changes

## HID control

The device accepts control commands via HID OUTPUT reports (report ID 3):

- Write `[0x03, 0x01]` to `/dev/hidraw*` to **mute**
- Write `[0x03, 0x02]` to `/dev/hidraw*` to **unmute**
- Write `[0x03, 0x03]` to `/dev/hidraw*` to **toggle**

The daemon receives these and sends INPUT reports to connected applications.

## Examples

**Toggle mute**

```bash
# Recommended — sends the HID OUTPUT report directly
virtual-headset-ctl toggle-mute

# Or manually to the hidraw device
echo -ne '\x03\x03' > /dev/hidraw0   # replace hidraw0 with your device
```

**Toggle via D-Bus**

```bash
virtual-headset-ctl toggle-mute-dbus

# Or directly with dbus-send
dbus-send --session --print-reply \
  --dest=com.github.virtual_headset \
  /com/github/virtual_headset \
  com.github.virtual_headset.Mute.Toggle
```

**Query current state**

```bash
dbus-send --session --print-reply \
  --dest=com.github.virtual_headset \
  /com/github/virtual_headset \
  com.github.virtual_headset.Mute.IsMuted
```

**Monitor for changes**

```bash
# JSON, suitable for status bars
virtual-headset-ctl monitor-mute

# Or directly with dbus-monitor
dbus-monitor --session \
  "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
```
