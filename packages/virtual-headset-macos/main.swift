// virtual-headset (macOS) — one resident agent.
//
// Forwards the real mic into Virtual_Headset_Microphone, a renamed BlackHole
// (packages/virtual-headset-driver) the call app picks as its mic, optionally
// denoising it on the way (DeepFilterNet in-process, or RNNoise via ffmpeg). It
// also presents the Virtual_Headset HID telephony device whose mute button and
// LEDs the call app syncs with. While the call is muted the real mic is released,
// so a Bluetooth headset drops back from mono HFP to stereo A2DP.
//
// The sketchybar `virtual_headset` item OWNS the bar icon and runs
// `virtual-headset panel <x>` on click, which posts TOGGLE so we open the settings
// panel under it. We only PUBLISH state to ~/.cache/virtual-headset (see
// publish()) + a CHANGED notification the item subscribes to.
//
// The default-input and device-list CoreAudio listeners restart the pipeline
// whenever the mic it should read (or the BlackHole device) changes — that's what
// makes "Default" follow AirPods/EarPods switches.

import AppKit

// CLI: `virtual-headset panel [x]` asks the running agent to toggle its panel;
// `virtual-headset mute|unmute|toggle-mute` presses the headset's mute button.
switch CommandLine.arguments.dropFirst().first {
case "panel":
  post(TOGGLE, CommandLine.arguments.dropFirst(2).first)
  exit(0)
case let cmd? where ["mute", "unmute", "toggle-mute"].contains(cmd):
  post(MUTE, cmd)
  exit(0)
default:
  break
}

if CommandLine.arguments.dropFirst().first == "bridge" { runBridge() }

signal(SIGPIPE, SIG_IGN)  // a dead ffmpeg must not kill us mid-write
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.dropFirst().first == "screenshot" {
  screenshots(to: CommandLine.arguments.dropFirst(2).first ?? ".")
  exit(0)
}
let controller = Controller()
signal(SIGTERM) { _ in
  controller.stop()
  exit(0)
}
app.run()
