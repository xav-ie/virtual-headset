# Troubleshooting

- [Zoom doesn't offer Virtual_Headset](#zoom-doesnt-offer-virtual_headset)
- [Mute presses do nothing](#mute-presses-do-nothing)
- [Firefox tab doesn't sync](#firefox-tab-doesnt-sync)
- [Linux: permission denied](#linux-permission-denied)
- [macOS: no Virtual_Headset_Microphone](#macos-no-virtual_headset_microphone)
- [macOS: the call hears nothing](#macos-the-call-hears-nothing)

## Zoom doesn't offer Virtual_Headset

1. **Pick the right mic.** Zoom only pairs the headset with a mic whose name
   contains `Virtual_Headset`: choose **Virtual_Headset_Microphone**, then turn
   **Sync buttons on headset** off and on again to bring the device picker back.
2. **Use a Chromium browser.** Firefox has no WebHID; use [the
   extension](browser-extension.md) there.
3. **Check the headset exists.**
   - Linux: `virtual-headset-ctl find-device` prints its `/dev/hidraw*`.
   - macOS: `hidutil list | grep Virtual_Headset` shows it while the app runs.
4. In a page's devtools console, `await navigator.hid.getDevices()` lists the
   headsets that site may use.

## Mute presses do nothing

The call app only listens once it's connected to the headset. When it is, it
lights the headset's mute light on every change, which you can watch:

- Linux: run `virtual-headset` in a terminal: it prints a line for each light
  change and for the call app opening the device.
- macOS: `cat ~/.cache/virtual-headset/call` says `muted` or `unmuted` in a
  connected call, and `none` otherwise. A mute press with no call connected
  flashes your menu bar item if it [watches for that](macos.md#your-menu-bar).

If the call app never connects, reconnect **Virtual_Headset** in its audio
settings.

## Firefox tab doesn't sync

- Check the daemon is running: `systemctl --user status virtual-headset`.
- Look for `[vh]` lines in the meeting tab's devtools console.
- Zoom or Meet may have changed their page; see [when Zoom or Meet
  change](browser-extension.md#when-zoom-or-meet-change).

## Linux: permission denied

- You need the `input` group: `groups | grep input`. Log out and back in after
  adding it.
- Check the udev rules loaded: `udevadm info /dev/uhid`.
- See [installation](installation.md#without-nix) for the rules.

## macOS: no Virtual_Headset_Microphone

The driver loads when macOS's audio service starts. Check it's installed, then
restart the service (all sound drops for a moment):

```sh
ls /Library/Audio/Plug-Ins/HAL/VirtualHeadset.driver
sudo killall coreaudiod
```

## macOS: the call hears nothing

- Open the panel: the status line under **Input** says what's wrong, such as a
  mic that can't be opened.
- With **Only while in use** on, the mic opens only once the call records from
  Virtual_Headset_Microphone, and closes while the call is muted.
- Check the boot argument is active: `sysctl -n kern.bootargs` must include
  `amfi_get_out_of_my_way=1`. Without it the app can neither make the headset
  nor use your mic.
- The app logs to `/tmp/virtual-headset.err.log` (or the module's `logDir`).
