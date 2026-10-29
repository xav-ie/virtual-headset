import AVFoundation
import AppKit
import CoreAudio

final class Controller: NSObject, NSSoundDelegate {
  let defaults: UserDefaults
  // A screenshot controller only draws the panel: no devices, audio or listeners.
  let live: Bool
  // Overrides the meter for screenshots, where no mic is open.
  var shownLevel: Double?
  // Noise suppression on top of forwarding; off passes the mic through untouched.
  // Kept under the "enabled" key so existing settings carry over.
  var denoise: Bool {
    get { defaults.bool(forKey: "enabled") }
    set { defaults.set(newValue, forKey: "enabled") }
  }
  var input: String {  // "" = follow the system default input
    get { defaults.string(forKey: "input") ?? "" }
    set { defaults.set(newValue, forKey: "input") }
  }
  // Run only while some app records from Virtual_Headset_Microphone, so the
  // mic — and its privacy indicator — is idle the rest of the time.
  var auto: Bool {
    get { defaults.object(forKey: "auto") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "auto") }
  }
  var model: String {
    // Unknown keys (a removed engine, e.g. the old "apple") fall back to the default.
    get { defaults.string(forKey: "model").flatMap { m in MODELS.contains { $0.key == m } ? m : nil } ?? "dfn" }
    set { defaults.set(newValue, forKey: "model") }
  }
  var mix: Double {
    get { defaults.object(forKey: "mix") as? Double ?? 1 }
    set { defaults.set(newValue, forKey: "mix") }
  }
  // Noise gate threshold in dBFS after denoising; GATE_OFF disables it. A close
  // mic (EarPods) hears your voice far louder than room noise, so the gate mutes
  // the gaps between your words without touching them.
  var gate: Double {
    get { defaults.object(forKey: "gate") as? Double ?? GATE_OFF }
    set { defaults.set(newValue, forKey: "gate") }
  }

  var procs: [Process] = []  // the arnndn ffmpeg, when RNNoise is the engine
  var standby = false
  var headset: Headset?
  // The call: "none", "muted" or "unmuted". A call app paired with the headset
  // reports it through the headset's LEDs (`hidCall`); a Firefox meeting tab,
  // which can't reach the headset, through the bridge (`browserCall`). The
  // headset wins when both are in a call. While muted the real mic is released
  // (Bluetooth headsets go back to A2DP).
  var hidCall = "none"
  var browserCall = "none"
  var call: String { hidCall != "none" ? hidCall : browserCall }
  var callMuted: Bool { call == "muted" }
  var showAdvanced = false
  var scrim: Scrim?
  var capture: Capture?
  var bhOut: BlackHoleOut?
  // Loaded once (~260 ms) and kept across captures, so an unmute doesn't wait
  // on it; prewarmed at launch while noise suppression is on.
  var deepFilter: DeepFilter?
  var running: Config?
  var status = "Off"
  var reconcileScheduled = false
  // Live RMS (dBFS) of the denoised signal — what the gate compares against.
  var level = -Double.infinity
  let meter = NSLevelIndicator()
  let meterText = NSTextField(labelWithString: "")
  // A/B test: record the raw mic once, then render it through the CURRENT settings
  // on every "Denoised" play — so you can tweak the gate and re-listen to one take.
  var recording = false
  // When the take in progress ends; the Record button counts down to it.
  var recordingEnds: Date?
  var takeSource: Capture?
  weak var recordButton: NSButton?
  var sound: NSSound?
  var playing: String?  // key into `takes`
  let playhead = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  let playTime = NSTextField(labelWithString: "")
  let gateText = NSTextField(labelWithString: "")
  let takes = [
    "pcm": NSTemporaryDirectory() + "virtual-headset-raw.f32",
    "den": NSTemporaryDirectory() + "virtual-headset-den.f32",
    "raw": NSTemporaryDirectory() + "virtual-headset-raw.wav",
    "out": NSTemporaryDirectory() + "virtual-headset-out.wav",
  ]

  let panel = PopupPanel(
    contentRect: NSRect(x: 0, y: 0, width: Controller.width, height: 40),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  // Keyboard navigation, independent of macOS's setting (see FocusRing): the panel's
  // controls in reading order, rebuilt with it; focus is kept by id across rebuilds.
  var focusables: [(id: String, view: NSView)] = []
  var focusID: String?
  var keyboardActive = false
  let ring = FocusRing(frame: .zero)
  var clickMonitor: Any?
  var lastMonitorClose: Date?

  init(live: Bool = true) {
    self.live = live
    // Screenshots keep their settings in a throwaway domain, never the user's.
    defaults = live ? .standard : UserDefaults(suiteName: "com.github.virtual-headset.screenshot")!
    super.init()
    // Settings saved under the agent's previous bundle id carry over once.
    if live, defaults.object(forKey: "migrated") == nil,
      let old = UserDefaults(suiteName: "com.x.mic-denoise")
    {
      for k in ["enabled", "input", "auto", "model", "mix", "gate"] {
        if let v = old.object(forKey: k) { defaults.set(v, forKey: k) }
      }
      defaults.set(true, forKey: "migrated")
    }
    panel.level = .popUpMenu
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.setAccessibilityLabel("Virtual Headset")
    panel.onKey = { [weak self] e in self?.key(e) ?? false }
    panel.onClick = { [weak self] in
      self?.keyboardActive = false
      self?.ring.isHidden = true
    }
    guard live else { return }
    if denoise, model == "dfn" {
      let limit = Float(mix * 100)
      DispatchQueue.global(qos: .utility).async {
        let df = DeepFilter(limitDB: limit)
        DispatchQueue.main.async { if self.deepFilter == nil { self.deepFilter = df } }
      }
    }

    DistributedNotificationCenter.default().addObserver(forName: TOGGLE, object: nil, queue: .main)
    {
      [weak self] note in
      let x = (note.object as? String).flatMap(Double.init).map { CGFloat($0) }
      self?.togglePanel(anchorX: x)
    }
    DistributedNotificationCenter.default().addObserver(forName: MUTE, object: nil, queue: .main) {
      [weak self] note in
      self?.mute(note.object as? String)
    }
    DistributedNotificationCenter.default().addObserver(
      forName: BROWSER_CALL, object: nil, queue: .main
    ) { [weak self] note in
      self?.setBrowserCall(note.object as? String ?? "none")
    }
    // The bridge has written the new `input` to our defaults already.
    DistributedNotificationCenter.default().addObserver(forName: INPUT, object: nil, queue: .main) {
      [weak self] _ in
      self?.reconcile()
    }
    // launchd's KeepAlive starts us again.
    DistributedNotificationCenter.default().addObserver(forName: RESTART, object: nil, queue: .main) {
      [weak self] _ in
      self?.stop()
      exit(0)
    }
    headset = Headset(
      led: { [weak self] muted, offHook in
        self?.setHidCall(!offHook ? "none" : muted ? "muted" : "unmuted")
      },
      command: { [weak self] c in self?.mute([1: "mute", 2: "unmute", 3: "toggle-mute"][c]) })
    for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
      var a = addr(sel)
      AudioObjectAddPropertyListenerBlock(SYSTEM, &a, .main) { [weak self] _, _ in
        self?.scheduleReconcile()
      }
    }
    // Builds before BlackHoleOut wrote via an ffmpeg audiotoolbox child; when launchd
    // replaces such an instance, that child is orphaned to ppid 1 and keeps writing
    // into BlackHole alongside us. Our own children never have ppid 1.
    let sweep = Process()
    sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    sweep.arguments = ["-9", "-P", "1", "-f", "audiotoolbox -audio_device_index"]
    try? sweep.run()
    sweep.waitUntilExit()
    reconcile()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, self.panel.isVisible else { return }
      self.updateMeter()
      self.updatePlayhead()
      self.updateRecordButton()
    }
    // ponytail: 1 s poll of process objects; listen to kAudioProcessPropertyIsRunningInput
    // per process if start-up lag ever matters.
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, self.auto, !self.callMuted,
        let bh = devices().first(where: { $0.uid == OUT_UID })
      else { return }
      if someoneRecords(from: bh.id) == (self.capture == nil) { self.reconcile() }
    }
  }

  // Device changes arrive in bursts (plugging a headset fires several).
  func scheduleReconcile() {
    guard !reconcileScheduled else { return }
    reconcileScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.reconcileScheduled = false
      self?.reconcile()
    }
  }

  // Resolve what ffmpeg should be doing right now, or why it can't.
  func desired() -> Result<Config, Failure> {
    let all = devices()
    guard let out = all.first(where: { $0.uid == OUT_UID }) else {
      return .failure(Failure(msg: "\(OUT_NAME) not installed"))
    }
    let mics = all.filter { $0.isInput && $0.uid != OUT_UID }
    // A picked mic that's unplugged falls back to the default rather than going silent.
    let mic =
      mics.first(where: { $0.name == input }) ?? mics.first(where: { $0.id == defaultInput() })
    guard let mic else {
      return .failure(Failure(msg: "No microphone available"))
    }
    return .success(
      Config(
        input: mic.name, uid: mic.uid, outID: out.id, denoise: denoise, model: model,
        // In-process engines apply strength live (no restart); only arnndn needs one.
        mix: denoise && model != "dfn" ? mix : 0))
  }

  func reconcile() {
    defer {
      publish()
      if panel.isVisible { buildContent() }
    }
    standby = false
    switch desired() {
    case .failure(let f):
      stop()
      status = f.msg
    case .success(let cfg):
      if callMuted {
        stop()
        status = "Mic released while the call is muted"
        return
      }
      if auto, let bh = devices().first(where: { $0.uid == OUT_UID }),
        !someoneRecords(from: bh.id)
      {
        stop()
        standby = true
        status = "Standby — opens when an app uses it"
        return
      }
      if cfg == running, capture != nil, procs.allSatisfy(\.isRunning) { return }
      stop()
      start(cfg)
    }
  }

  func ffmpeg(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: FFMPEG)
    p.arguments =
      // No `-fflags nobuffer`: with a pipe input it makes ffmpeg emit nothing at all.
      // No probing: the format is given, and by default ffmpeg buffers ~5 s of input
      // (analyzeduration) before opening the output — the real-time BlackHole writer
      // then plays that backlog forever, i.e. a permanent ~5 s lag.
      ["-hide_banner", "-loglevel", "warning", "-nostdin", "-flags", "low_delay"]
      + ["-probesize", "32", "-analyzeduration", "0"]
      + ["-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "pipe:0"] + args
    return p
  }

  // DeepFilterNet: mic → DeepFilter → Post → BlackHole, all in-process.
  // RNNoise (arnndn is ffmpeg-only): mic → ffmpeg pipe → Post → BlackHole, with a
  // jitter buffer sized for ffmpeg's ~85 ms output lumps.
  // Noise suppression off: mic → Post (ungated) → BlackHole.
  func start(_ cfg: Config) {
    let viaFFmpeg = cfg.denoise && cfg.model != "dfn"
    // AVCapture hands over ~557-frame (11.6 ms) buffers; ffmpeg's pipe output, 4096.
    guard let out = BlackHoleOut(device: cfg.outID, burst: viaFFmpeg ? 4096 : 560) else {
      status = "Can't open \(OUT_NAME) for output"
      return
    }
    bhOut = out
    let post = Post(
      out: out, threshold: { [weak self] in cfg.denoise ? self?.gate ?? GATE_OFF : GATE_OFF },
      level: { [weak self] db in DispatchQueue.main.async { self?.level = db } })

    let sink: (Data) -> Void
    if viaFFmpeg {
      let den = ffmpeg(
        ["-af", filters(cfg), "-f", "f32le", "-ar", "48000", "-ac", "1", "-flush_packets", "1",
         "pipe:1"])
      let pcm = Pipe()
      let mid = Pipe()
      den.standardInput = pcm
      den.standardOutput = mid
      var pending = Data()
      mid.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty else {
          h.readabilityHandler = nil  // EOF
          return
        }
        pending.append(data)
        let whole = pending.count / 4 * 4
        guard whole > 0 else { return }
        var chunk = Data(pending.prefix(whole))
        pending.removeFirst(whole)
        chunk.withUnsafeMutableBytes { post.feed($0.bindMemory(to: Float.self)) }
      }
      den.terminationHandler = { [weak self] dead in
        DispatchQueue.main.async {
          guard let self, self.procs.contains(dead) else { return }  // a deliberate stop()
          self.stop()
          self.status = "ffmpeg exited (\(dead.terminationStatus)), retrying…"
          self.publish()
          if self.panel.isVisible { self.buildContent() }
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reconcile() }
        }
      }
      do {
        try den.run()
      } catch {
        stop()
        status = "ffmpeg failed: \(error.localizedDescription)"
        return
      }
      procs = [den]
      let w = pcm.fileHandleForWriting
      sink = { try? w.write(contentsOf: $0) }  // throws (not SIGPIPE, ignored) once ffmpeg dies
    } else if !cfg.denoise {
      sink = { data in
        var chunk = data
        chunk.withUnsafeMutableBytes { post.feed($0.bindMemory(to: Float.self)) }
      }
    } else {
      guard let df = deepFilter ?? DeepFilter(limitDB: Float(mix * 100)) else {
        stop()
        status = "Can't load DeepFilterNet"
        return
      }
      df.limitDB = Float(mix * 100)
      deepFilter = df
      sink = { data in
        var chunk = data
        chunk.withUnsafeMutableBytes {
          let x = $0.bindMemory(to: Float.self)
          df.process(x)
          post.feed(x)
        }
      }
    }

    guard let c = Capture(uid: cfg.uid, sink: sink) else {
      stop()
      status = "Can't open \(cfg.input)"
      return
    }
    capture = c
    running = cfg
    status = "Using \(cfg.input)"
  }

  // Strength maps to arnndn's mix, or DeepFilterNet's attenuation limit (c0, 0–100 dB).
  func filters(_ cfg: Config) -> String {
    switch cfg.model {
    case "dfn":
      "aresample=48000,aformat=channel_layouts=mono,ladspa=f=\(DFN_LADSPA):p=deep_filter_mono:c=c0=\(Int(cfg.mix * 100))"
    default:
      "aresample=48000,arnndn=m=\(Bundle.main.resourcePath!)/models/\(cfg.model).rnnn:mix=\(cfg.mix)"
    }
  }

  func stop() {
    capture?.stop()
    capture = nil
    bhOut?.stop()
    bhOut = nil
    let dead = procs
    procs = []
    running = nil
    // SIGKILL, not terminate(): ffmpeg's graceful SIGTERM path hangs in the
    // audiotoolbox teardown, leaving stale writers summed into BlackHole. Live audio
    // has nothing to flush.
    for p in dead where p.isRunning { kill(p.processIdentifier, SIGKILL) }
  }

  // On a headset call the press only asks: the call app's LED report is what
  // changes `call`. A Firefox call has no headset to press, so the press sets it,
  // and the bridge has the extension click the tab's mic button to match.
  func mute(_ cmd: String?) {
    guard call != "none" else { return nudge() }
    switch cmd {
    case "mute" where !callMuted, "unmute" where callMuted, "toggle-mute":
      if hidCall != "none" {
        headset?.pressMute()
      } else {
        setBrowserCall(callMuted ? "unmuted" : "muted")
      }
    default: break
    }
  }

  // Nothing paired to mute: the bar item flashes on this marker, so a mute press
  // outside a call isn't silently dropped.
  func nudge() {
    try? "".write(toFile: "\(CACHE)/nudge", atomically: true, encoding: .utf8)
    post(CHANGED, nil)
  }

  func setHidCall(_ state: String) {
    guard state != hidCall else { return }
    hidCall = state
    reconcile()
  }

  func setBrowserCall(_ state: String) {
    guard ["none", "muted", "unmuted"].contains(state), state != browserCall else { return }
    browserCall = state
    reconcile()
  }

  func publish() {
    let dir = CACHE
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let state =
      callMuted
      ? "muted" : capture != nil ? (denoise ? "on" : "raw") : standby ? "standby" : "error"
    try? state.write(toFile: "\(dir)/state", atomically: true, encoding: .utf8)
    try? call.write(toFile: "\(dir)/call", atomically: true, encoding: .utf8)
    post(CHANGED, nil)
  }
}
