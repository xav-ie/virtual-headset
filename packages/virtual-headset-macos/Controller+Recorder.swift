import AppKit
import BarPanels

extension Controller {
  // Record 8 s of raw mic, then play it as-is or through the current settings;
  // a playhead to scrub while a take plays.
  func testRows() -> [NSView] {
    let haveTakes = !recording && FileManager.default.fileExists(atPath: takes["raw"]!)
    let record = HoverRow(
      "Record a Test",
      icon: NSImage(
        systemSymbolName: recording ? "stop.circle" : "record.circle", accessibilityDescription: nil),
      detail: "8 s")
    record.onClick = { [weak self] in self?.record() }
    recordRow = record
    updateRecordButton()
    var rows: [NSView] = [record]
    for (key, title) in [("raw", "Play Original"), ("out", "Play Denoised")] {
      let row = HoverRow(
        title,
        icon: NSImage(
          systemSymbolName: playing == key ? "stop.fill" : "play.fill", accessibilityDescription: nil),
        enabled: haveTakes)
      if haveTakes { row.onClick = { [weak self] in self?.toggle(key) } }
      rows.append(row)
    }
    guard playing != nil else { return rows }
    playhead.target = self
    playhead.action = #selector(seek(_:))
    updatePlayhead()
    return rows + [field("Playhead", playhead, valueLabel(playTime.stringValue, playTime))]
  }
  // "8 s", "7 s", … while a take records: whole seconds left, rounded up.
  // Pressing the row again meanwhile ends the take early.
  func updateRecordButton() {
    guard let recordRow else { return }
    guard recording, let end = recordingEnds else { return recordRow.setDetail("8 s") }
    let left = Int(max(0, end.timeIntervalSinceNow).rounded(.up))
    recordRow.setDetail("\(max(left, 1)) s")
    recordRow.setAccessibilityLabel("Stop recording, \(left) seconds left")
  }

  func updatePlayhead() {
    guard let sound, playing != nil else { return }
    playhead.maxValue = max(sound.duration, 0.1)
    playhead.doubleValue = sound.currentTime
    playTime.stringValue = String(format: "%.1f s", sound.currentTime)
  }
  @objc func seek(_ s: NSSlider) { sound?.currentTime = s.doubleValue }
  // Records from the live capture, or, while the mic is closed (between calls, or
  // muted), opens the mic just for the take.
  // Records 8 s; pressed again while recording, it stops and keeps the take so far.
  func record() {
    if recording {
      takeSource?.finishTake()
      return
    }
    var borrowed: Capture?
    if capture == nil {
      guard case .success(let cfg) = desired(), let c = Capture(uid: cfg.uid, sink: { _ in }) else {
        status = "Can't open the mic to record"
        buildContent()
        return
      }
      borrowed = c
    }
    guard let source = capture ?? borrowed else { return }
    stopPlayback()
    recording = true
    recordingEnds = Date().addingTimeInterval(8)
    takeSource = source
    buildContent()
    source.record(seconds: 8) { [weak self] data in
      borrowed?.stop()
      borrowed = nil  // the take's callback held it
      guard let self else { return }
      self.takeSource = nil
      try? data.write(to: URL(fileURLWithPath: self.takes["pcm"]!))
      self.render(self.takes["pcm"]!, self.takes["raw"]!, filters: nil)
      self.recording = false
      if self.panel.isVisible { self.buildContent() }
    }
  }
  // Raw f32 → `dest`, optionally through ffmpeg filters; offline, so it's fast.
  // A `dest` ending in .f32 stays raw, anything else becomes a wav.
  func render(_ src: String, _ dest: String, filters: String?) {
    var args: [String] = ["-y", "-hide_banner", "-loglevel", "error", "-nostdin"]
    args += ["-f", "f32le", "-ar", "48000", "-ac", "1", "-i", src]
    if let filters { args += ["-af", filters] }
    args += dest.hasSuffix(".f32") ? ["-f", "f32le"] : ["-c:a", "pcm_s16le"]
    args.append(dest)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: FFMPEG)
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
  }
  // The take as the call would hear it with the CURRENT settings: same denoiser
  // chain, then the same Gate code the live path runs.
  func renderDenoised() {
    let cfg = Config(input: "", uid: "", outID: 0, denoise: true, model: model, mix: mix)
    let den = takes["den"]!
    render(takes["pcm"]!, den, filters: filters(cfg))
    guard var data = FileManager.default.contents(atPath: den) else { return }
    var g = Gate()
    _ = data.withUnsafeMutableBytes { g.process($0.bindMemory(to: Float.self), thresholdDB: gate) }
    try? data.write(to: URL(fileURLWithPath: den))
    render(den, takes["out"]!, filters: nil)
  }
  // Clicking the playing take stops it; the other take switches over.
  func toggle(_ key: String) {
    let wasPlaying = playing
    stopPlayback()
    if wasPlaying != key {
      if key == "out" { renderDenoised() }
      sound = NSSound(contentsOfFile: takes[key]!, byReference: false)
      sound?.delegate = self
      if sound?.play() == true { playing = key }
    }
    buildContent()
  }
  func stopPlayback() {
    sound?.delegate = nil  // a manual stop isn't a "finished" callback
    sound?.stop()
    sound = nil
    playing = nil
  }
  func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
    stopPlayback()
    if panel.isVisible { buildContent() }
  }
}
