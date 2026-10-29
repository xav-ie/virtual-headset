import Foundation

let TOGGLE = Notification.Name("com.github.virtual-headset.toggle-panel")
let CHANGED = Notification.Name("com.github.virtual-headset.changed")
let MUTE = Notification.Name("com.github.virtual-headset.mute")
// From the Firefox bridge (see runBridge): a meeting tab's mute, the mic to
// forward, and a restart.
let BROWSER_CALL = Notification.Name("com.github.virtual-headset.browser-call")
let INPUT = Notification.Name("com.github.virtual-headset.input")
let RESTART = Notification.Name("com.github.virtual-headset.restart")
let OUT_NAME = "Virtual_Headset_Microphone"
let OUT_UID = "Virtual_Headset_Microphone_UID"
// State for bar integrations (see publish()).
let CACHE = ("~/.cache/virtual-headset" as NSString).expandingTildeInPath
let GATE_OFF = -70.0

func post(_ name: Notification.Name, _ object: String?) {
  DistributedNotificationCenter.default().postNotificationName(
    name, object: object, userInfo: nil, deliverImmediately: true)
}

// "dfn" is DeepFilterNet 3 (LADSPA): far stronger on non-stationary noise like
// music, ~9% of a core. The rest are RNNoise via arnndn, GregorR/rnnoise-models:
// expected signal × expected noise. "Recording" noise = mic hiss/room tone;
// "general" = everything else (keyboard, fans, street).
let MODELS: [(key: String, label: String)] = [
  ("dfn", "DeepFilterNet 3"),
  ("lq", "RNNoise: voice, everyday noise"),
  ("bd", "RNNoise: voice, mic/room noise"),
  ("sh", "RNNoise: speech only, mic/room noise"),
  ("mp", "RNNoise: any sound, everyday noise"),
  ("cb", "RNNoise: any sound, mic/room noise"),
]
