import Foundation

// MARK: Firefox bridge

// `virtual-headset bridge` (installed as bin/virtual-headset-bridge): the native-
// messaging host Firefox starts for the extension. It speaks the Linux bridge's
// protocol (packages/virtual-headset/src/bin/virtual-headset-bridge.rs), so the
// extension is the same on both: each message is a 4-byte native-endian length
// and UTF-8 JSON. It relays between the extension and the running agent through
// distributed notifications. Firefox has no WebHID, so its Zoom and Meet tabs
// never reach the Virtual_Headset device; through the bridge the tab becomes the
// call instead:
//   extension → agent: the tab's mute (setMute) and whether a meeting tab is
//     open (call) as BROWSER_CALL; the toolbar's toggle as a MUTE press; the mic
//     to forward as `input` in the agent's defaults, then INPUT
//   agent → extension: the call's mute, as state, on every CHANGED
func runBridge() -> Never {
  let out = FileHandle.standardOutput
  func send(_ msg: [String: Any]) {
    guard let body = try? JSONSerialization.data(withJSONObject: msg) else { return }
    var length = UInt32(body.count)
    out.write(Data(bytes: &length, count: 4) + body)
  }
  func callFile() -> String {
    (try? String(contentsOfFile: "\(CACHE)/call", encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "none"
  }
  // The call's mute, if there's a call.
  func sendState() {
    switch callFile() {
    case "muted": send(["type": "state", "muted": true])
    case "unmuted": send(["type": "state", "muted": false])
    default: break
    }
  }
  func sendSources() {
    let chosen = UserDefaults.standard.string(forKey: "input") ?? ""
    let def = defaultInput()
    let mics = devices().filter { $0.isInput && $0.uid != OUT_UID }
    send([
      "type": "sources",
      "sources": mics.map {
        ["name": $0.name, "description": $0.name, "default": $0.id == def, "configured": $0.name == chosen]
      },
    ])
  }
  func choose(_ input: String) {
    UserDefaults.standard.set(input, forKey: "input")
    post(INPUT, nil)
    sendSources()
  }

  // The tab's last reported mute, so a newly opened meeting tab rejoins as the call.
  var tabMuted: Bool?
  func handle(_ msg: [String: Any]) {
    switch msg["type"] as? String {
    case "setMute":
      let muted = msg["muted"] as? Bool ?? false
      tabMuted = muted
      post(BROWSER_CALL, muted ? "muted" : "unmuted")
    case "call":
      if msg["active"] as? Bool != true {
        post(BROWSER_CALL, "none")
      } else if let tabMuted {
        post(BROWSER_CALL, tabMuted ? "muted" : "unmuted")
      }
    case "toggle": post(MUTE, "toggle-mute")
    case "query": sendState()
    case "listSources": sendSources()
    case "setSource": choose(msg["name"] as? String ?? "")
    case "clearSource": choose("")
    case "restartService": post(RESTART, nil)
    case "ping": send(["type": "pong"])
    case let type: send(["type": "error", "message": "unknown message type \(type ?? "none")"])
    }
  }

  DistributedNotificationCenter.default().addObserver(forName: CHANGED, object: nil, queue: .main) {
    _ in sendState()
  }
  // Read on a thread of its own; handle on the main queue, where the
  // notifications arrive too, so state is only touched there.
  Thread.detachNewThread {
    let input = FileHandle.standardInput
    while true {
      let header = input.readData(ofLength: 4)
      guard header.count == 4 else { break }
      let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
      let body = input.readData(ofLength: Int(length))
      guard body.count == Int(length) else { break }
      DispatchQueue.main.async {
        guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
          return send(["type": "error", "message": "invalid message"])
        }
        handle(msg)
      }
    }
    // Firefox closed the port: the tab's call ends with it.
    DispatchQueue.main.async {
      post(BROWSER_CALL, "none")
      exit(0)
    }
  }
  sendState()
  RunLoop.main.run()
  exit(0)
}
