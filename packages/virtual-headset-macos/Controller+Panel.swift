import AppKit
import BarPanels

extension Controller {
  // MARK: Panel

  // The call first, then the mic it forwards, then noise suppression (an add-on
  // on top of forwarding, with its own A/B test); the setup hint only outside
  // calls. Picking one of several is a checkmark row, on/off a switch row.
  func panelContent() -> (items: [NSView], inset: [NSView]) {
    var items: [NSView] = []
    var inset: [NSView] = []
    func add(_ v: NSView, inset isInset: Bool = false) {
      items.append(v)
      if isInset { inset.append(v) }
    }

    let state = call == "none" ? "Not in a call" : callMuted ? "Muted" : "Live"
    add(BarPanel.title("Virtual Headset", detail: state), inset: true)
    if call != "none" {
      let row = HoverRow(
        "Mute Call",
        icon: NSImage(
          systemSymbolName: callMuted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: nil),
        iconTint: callMuted ? SECONDARY_TEXT : .systemRed,
        toggle: ("virtual-headset.mute", callMuted))
      row.onClick = { [weak self] in self?.mute("toggle-mute") }
      add(row)
    }

    add(separatorBox())
    add(BarPanel.sectionTitle("Microphone"), inset: true)
    // "Default" follows the system's input; the status line names the mic in use.
    let mics = devices().filter { $0.isInput && $0.uid != OUT_UID }
    for (title, name) in [("Default", "")] + mics.map({ ($0.name, $0.name) }) {
      let row = HoverRow(title, icon: NSImage(systemSymbolName: "mic", accessibilityDescription: nil), mark: .check(input == name))
      row.onClick = { [weak self] in
        self?.input = name
        self?.reconcile()
      }
      add(row)
    }
    // The meter only means something while the mic is open.
    if capture != nil || shownLevel != nil { add(meterRow(), inset: true) }
    add(note(status), inset: true)

    add(separatorBox())
    let suppression = HoverRow(
      "Noise Suppression", toggle: ("virtual-headset.denoise", denoise), title: true)
    suppression.onClick = { [weak self] in
      guard let self else { return }
      denoise.toggle()
      reconcile()
    }
    add(suppression)
    if denoise {
      add(strengthRow(), inset: true)
      testRows().forEach { add($0, inset: !($0 is HoverRow)) }
    }

    // Settings almost nobody should change: keeping the mic open, and (the
    // benchmarks favour DeepFilterNet everywhere, the gate costs speech
    // quality) the engine and gate.
    add(separatorBox())
    let advanced = HoverRow("Advanced", expanded: showAdvanced)
    advanced.onClick = { [weak self] in
      guard let self else { return }
      showAdvanced.toggle()
      buildContent()
    }
    add(advanced)
    if showAdvanced {
      // The switch reads "Keep the mic open", the inverse of `auto`.
      let keepOpen = HoverRow("Keep Mic Open Between Calls", toggle: ("virtual-headset.keep-open", !auto))
      keepOpen.onClick = { [weak self] in
        guard let self else { return }
        auto.toggle()
        reconcile()
      }
      add(keepOpen)
      add(
        note(
          "Calls start a moment sooner, but your mic stays in use, and Bluetooth headsets in hands-free audio, even when nothing is listening."
        ), inset: true)
      if denoise {
        add(BarPanel.sectionTitle("Model"), inset: true)
        for m in MODELS {
          let row = HoverRow(m.label, mark: .check(model == m.key))
          row.onClick = { [weak self] in
            self?.model = m.key
            self?.reconcile()
          }
          add(row)
        }
        add(gateRow(), inset: true)
      }
    }

    if call == "none" {
      add(separatorBox())
      add(note("In the call app, choose “\(OUT_NAME)” as the mic."), inset: true)
    }
    return (items, inset)
  }

  // A labelled control across the panel: "Strength  ───●──  30 dB". Keyed by
  // its label, so a rebuild moves it rather than fading it for a new value.
  func field(_ title: String, _ control: NSView, _ value: NSTextField? = nil, height: CGFloat = ROW_H)
    -> NSView
  {
    let v = NSView(frame: NSRect(x: 0, y: 0, width: INSET_W, height: ROW_H))
    v.identifier = NSUserInterfaceItemIdentifier(title)
    let l = NSTextField(labelWithString: title)
    l.font = .systemFont(ofSize: 12)
    l.frame = NSRect(x: 0, y: (ROW_H - 16) / 2, width: 60, height: 16)
    let valueWidth: CGFloat = value == nil ? 0 : 50
    control.frame = NSRect(
      x: 64, y: (ROW_H - height) / 2, width: INSET_W - 64 - valueWidth, height: height)
    control.setAccessibilityLabel(title)
    value?.frame = NSRect(x: INSET_W - 46, y: (ROW_H - 16) / 2, width: 46, height: 16)
    for sub in [l, control, value].compactMap({ $0 }) { v.addSubview(sub) }
    return v
  }

  func valueLabel(_ s: String, _ l: NSTextField = NSTextField(labelWithString: "")) -> NSTextField {
    l.stringValue = s
    l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    l.textColor = SECONDARY_TEXT
    l.alignment = .right
    return l
  }

  // Yellow = above the gate (passes through), green = below it (muted). Set the
  // gate between where the meter sits while you're silent and while you talk.
  func meterRow() -> NSView {
    meter.levelIndicatorStyle = .continuousCapacity
    meter.minValue = GATE_OFF
    meter.maxValue = 0
    meter.warningValue = meterWarning
    meter.criticalValue = -3
    meter.controlSize = .small
    updateMeter()
    return field("Level", meter, valueLabel(meterText.stringValue, meterText), height: 12)
  }
  // Green below the gate (muted), yellow above it, red near clipping. With the gate
  // off, warning == critical: a warning above critical would invert the colours.
  var meterWarning: Double { gate > GATE_OFF ? gate : -3 }
  func updateMeter() {
    let v = shownLevel ?? (capture == nil ? -Double.infinity : level)
    meter.doubleValue = max(GATE_OFF, v)
    meterText.stringValue = v.isFinite ? "\(Int(v.rounded())) dB" : "—"
  }

  // DeepFilterNet: the attenuation limit (mix × 100 dB). Past ~40 dB it sounds the
  // same as unlimited (benchmarked), so the slider tops out there as "Max".
  // RNNoise: arnndn's wet/dry mix, which can't change live — restart on release.
  func strengthRow() -> NSView {
    let dfn = model == "dfn"
    let top = dfn ? 0.4 : 1
    let s = accentSlider(
      value: min(mix, top), min: 0, max: top, target: self, action: #selector(mixChanged(_:)))
    s.isContinuous = false
    let text = !dfn ? "\(Int(mix * 100))%" : mix >= top ? "Max" : "\(Int(mix * 100)) dB"
    return field("Strength", s, valueLabel(text))
  }

  func gateRow() -> NSView {
    let s = accentSlider(
      value: gate, min: GATE_OFF, max: -10, target: self, action: #selector(gateChanged(_:)))
    s.isContinuous = true  // the gate is live: no restart, so track the drag
    return field("Gate", s, valueLabel(gate > GATE_OFF ? "\(Int(gate)) dB" : "Off", gateText))
  }

  @objc func gateChanged(_ s: NSSlider) {
    gate = s.doubleValue.rounded()
    gateText.stringValue = gate > GATE_OFF ? "\(Int(gate)) dB" : "Off"
    meter.warningValue = meterWarning
  }
  @objc func mixChanged(_ s: NSSlider) {
    mix = (s.doubleValue * 100).rounded() / 100
    deepFilter?.limitDB = Float(mix * 100)  // live; reconcile() only restarts arnndn
    reconcile()
  }
}
