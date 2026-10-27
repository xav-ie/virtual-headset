# macOS

On macOS the headset is one resident agent (`packages/virtual-headset-macos`)
plus a loopback audio driver (`packages/virtual-headset-driver`):

- **Virtual_Headset_Microphone**: a renamed [BlackHole](https://github.com/ExistentialAudio/BlackHole)
  build. The agent forwards your real mic into it, optionally removing background
  noise on the way with [DeepFilterNet 3](https://github.com/Rikorose/DeepFilterNet)
  (or [RNNoise](https://github.com/xiph/rnnoise)). Pick it as the mic in your
  call app.
- **Virtual_Headset**: a HID telephony headset with the same reports as the Linux
  daemon, created from userspace with `IOHIDUserDevice` (no DriverKit). Zoom
  pairs it with the mic because the mic's name contains `Virtual_Headset`.

While the call is muted (the call app's mute LED), the agent releases the real
mic. A Bluetooth headset then switches back from mono hands-free (HFP) to stereo
(A2DP), and back to HFP when you unmute.

## Requirements

- `amfi_get_out_of_my_way=1` in the boot args (with SIP off). Creating a virtual
  HID device needs the `com.apple.developer.hid.virtual.device` entitlement,
  which an ad-hoc signature only satisfies with AMFI relaxed.
- Nix with `sandbox = relaxed` (or off): the build re-signs the app with Apple's
  `codesign`.
- The driver copied to `/Library/Audio/Plug-Ins/HAL/`, then `sudo killall coreaudiod`.

## Usage

```sh
nix build github:xav-ie/virtual-headset
./result/Applications/virtual-headset.app/Contents/MacOS/virtual-headset &   # the agent
./result/bin/virtual-headset panel         # toggle the settings panel
./result/bin/virtual-headset toggle-mute   # press the headset's mute button
./result/bin/virtual-headset mute          # …or mute / unmute explicitly
```

In Zoom: choose **Virtual_Headset_Microphone** as the mic, then connect
**Virtual_Headset** when Zoom asks for a HID device ("Sync buttons on headset").

The settings panel has the call's Mute button, then the real mic (input, level,
and whether to open it only while an app uses Virtual_Headset_Microphone), then
noise suppression: its strength and an 8 s A/B test, with the engine and a noise
gate under Advanced.

The agent publishes state for bar integrations and posts the distributed
notification `com.github.virtual-headset.changed` whenever it changes:

- `~/.cache/virtual-headset/state`: `on` (denoising) / `raw` (forwarding, noise
  suppression off) / `muted` / `standby` / `error`
- `~/.cache/virtual-headset/call`: `none` / `muted` / `unmuted`, from the call
  app's LEDs
- `~/.cache/virtual-headset/nudge`: appears when a mute press had no call to
  mute; a bar item can flash and delete it

Run the agent from launchd (`KeepAlive`) to start it at login. The first time it
opens the mic, macOS asks for microphone access for `com.github.virtual-headset`.
