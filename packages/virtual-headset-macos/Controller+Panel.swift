import AppKit

extension Controller {
  // MARK: Panel

  func togglePanel(anchorX: CGFloat?) {
    if panel.isVisible { return closePanel() }
    // Clicking the bar item to dismiss trips the click-outside monitor first.
    if let t = lastMonitorClose, Date().timeIntervalSince(t) < 0.3 {
      lastMonitorClose = nil
      return
    }
    buildContent()
    let scr = NSScreen.main ?? NSScreen.screens.first!
    var x = anchorX ?? (scr.frame.maxX - panel.frame.width - 8)
    if x > scr.frame.width { x /= scr.backingScaleFactor }  // sketchybar reports device px
    x = min(max(scr.frame.minX + 4, x), scr.frame.maxX - panel.frame.width - 4)
    panel.setFrameTopLeftPoint(NSPoint(x: x, y: scr.visibleFrame.maxY - 2))
    keyboardActive = false
    focusID = nil
    panel.orderFrontRegardless()
    panel.makeKey()
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] _ in
      self?.lastMonitorClose = Date()
      self?.closePanel()
    }
  }

  func closePanel() {
    panel.orderOut(nil)
    if let m = clickMonitor {
      NSEvent.removeMonitor(m)
      clickMonitor = nil
    }
  }

  func label(_ s: String, size: CGFloat = 12, secondary: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = .systemFont(ofSize: size)
    l.textColor = secondary ? .secondaryLabelColor : .labelColor
    l.lineBreakMode = .byTruncatingTail
    return l
  }

  static let width: CGFloat = 340

  // Small grey section title, like Control Center's.
  func heading(_ s: String) -> NSTextField {
    let l = label(s.uppercased(), size: 11, secondary: true)
    l.font = .systemFont(ofSize: 11, weight: .semibold)
    return l
  }

  func separator() -> NSView {
    let b = NSBox()
    b.boxType = .separator
    return b
  }

  func wrapping(_ s: String) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: 11)
    l.textColor = .secondaryLabelColor
    l.preferredMaxLayoutWidth = Controller.width - 28
    return l
  }

  // Label column + control column, so every control starts at the same x.
  func grid(_ rows: [(String, NSView)]) -> NSGridView {
    // VoiceOver names a row's popup, slider or meter after the row's title.
    for (title, view) in rows where !title.isEmpty {
      let control = ([view] + view.subviews).first {
        $0 is NSPopUpButton || $0 is NSSlider || $0 is NSLevelIndicator
      }
      control?.setAccessibilityLabel(title)
    }
    let g = NSGridView(views: rows.map { [label($0.0), $0.1] })
    g.columnSpacing = 10
    g.rowSpacing = 8
    g.column(at: 0).width = 66
    g.column(at: 1).xPlacement = .fill
    g.rowAlignment = .firstBaseline
    for r in 0..<g.numberOfRows { g.row(at: r).yPlacement = .center }
    return g
  }

  // The call's mic state is the most prominent thing: a tinted glyph, the state,
  // and the button that flips it.
  func callRow() -> NSView {
    guard call != "none" else {
      let l = label("Not in a call", size: 13, secondary: true)
      return NSStackView(views: [symbol("mic", .tertiaryLabelColor), l])
    }
    let state = label(callMuted ? "Muted" : "Live", size: 15)
    state.font = .systemFont(ofSize: 15, weight: .semibold)
    let glyph =
      callMuted ? symbol("mic.slash.fill", .secondaryLabelColor) : symbol("mic.fill", .systemRed)
    let b = focusable("mute", NSButton(
      title: callMuted ? "Unmute" : "Mute", target: self, action: #selector(muteClicked)))
    b.bezelStyle = .rounded
    b.setAccessibilityLabel(callMuted ? "Unmute the call" : "Mute the call")
    return NSStackView(views: [glyph, state, NSView(), b])
  }

  func symbol(_ name: String, _ tint: NSColor) -> NSImageView {
    let v = NSImageView(
      image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))!)
    v.contentTintColor = tint
    v.setAccessibilityElement(false)  // decoration: the state is spelled out beside it
    return v
  }

  // Call mute first, then the mic it forwards, then noise suppression (an add-on on
  // top of forwarding, with its own A/B test); the setup hint only outside calls.
  func buildContent() {
    focusables = []
    let mics = devices().filter { $0.isInput && $0.uid != OUT_UID }
    let micPop = focusable("input", NSPopUpButton())
    // "Default" alone: the status line below names the mic actually in use.
    micPop.addItem(withTitle: "Default")
    micPop.lastItem?.representedObject = ""
    for m in mics {
      micPop.addItem(withTitle: m.name)
      micPop.lastItem?.representedObject = m.name
    }
    micPop.selectItem(at: max(0, micPop.indexOfItem(withRepresentedObject: input)))
    micPop.target = self
    micPop.action = #selector(micPicked(_:))


    let toggle = focusable("denoise", NSSwitch())
    toggle.setAccessibilityLabel("Noise suppression")
    toggle.controlSize = .small
    toggle.state = denoise ? .on : .off
    toggle.target = self
    toggle.action = #selector(toggled(_:))

    var views: [NSView] = [
      callRow(),
      separator(),
      heading("Microphone"),
      // The meter only means something while the mic is open.
      grid([("Input", micPop)] + (capture != nil || shownLevel != nil ? [("Level", meterRow())] : [])),
      wrapping(status),
      separator(),
      NSStackView(views: [heading("Noise suppression"), NSView(), toggle]),
    ]

    if denoise { views.append(grid([("Strength", strengthRow()), ("Test", testRow())])) }

    // Settings almost nobody should change: keeping the mic open, and (the
    // benchmarks favour DeepFilterNet everywhere, the gate costs speech quality)
    // the engine and gate. A plain chevron, not a disclosure bezel: the panel
    // rebuilds on every click, which cut the bezel's arrow animation short.
    let chevron = NSImage(
      systemSymbolName: showAdvanced ? "chevron.down" : "chevron.right",
      accessibilityDescription: nil)!
      .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))!
    let disclose = focusable("advanced", NSButton(
      title: "Advanced", image: chevron, target: self, action: #selector(advancedToggled)))
    disclose.setAccessibilityExpanded(showAdvanced)
    disclose.isBordered = false
    disclose.imagePosition = .imageLeading
    disclose.contentTintColor = .secondaryLabelColor
    disclose.font = .systemFont(ofSize: 12)
    views += [separator(), NSStackView(views: [disclose, NSView()])]
    if showAdvanced {
      let keepOpen = focusable("keep-open", NSButton(
        checkboxWithTitle: "Keep the mic open between calls", target: self,
        action: #selector(autoToggled(_:))))
      keepOpen.state = auto ? .off : .on
      views += [
        keepOpen,
        wrapping(
          "Calls start a moment sooner, but your mic stays in use, and Bluetooth headsets in hands-free audio, even when nothing is listening."
        ),
      ]
      if denoise {
        let modelPop = focusable("model", NSPopUpButton())
        for m in MODELS {
          modelPop.addItem(withTitle: m.label)
          modelPop.lastItem?.representedObject = m.key
        }
        modelPop.selectItem(at: max(0, modelPop.indexOfItem(withRepresentedObject: model)))
        modelPop.target = self
        modelPop.action = #selector(modelPicked(_:))
        views.append(grid([("Model", modelPop), ("Gate", gateRow())]))
      }
    }

    if call == "none" {
      views += [separator(), wrapping("In the call app, choose “\(OUT_NAME)” as the mic.")]
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    for v in stack.arrangedSubviews {
      v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
    }
    stack.widthAnchor.constraint(equalToConstant: Controller.width).isActive = true
    let size = stack.fittingSize
    stack.frame = NSRect(origin: .zero, size: size)

    let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    let frame = NSRect(origin: .zero, size: size)
    // One backdrop for the panel's life, with only its content swapped.
    let scrim = self.scrim ?? backdrop(frame)
    scrim.subviews.forEach { $0.removeFromSuperview() }
    scrim.addSubview(stack)
    scrim.addSubview(ring)
    panel.setContentSize(size)
    if panel.isVisible { panel.setFrameTopLeftPoint(topLeft) }
    showRing()
  }

  // A frosted popover material, always drawn active, under a translucent scrim.
  // Not Liquid Glass: its clear style turns far more transparent whenever the
  // panel is the key window, which it is while it takes the keyboard, so the
  // panel's look jumped with every click; the regular style squares off the
  // corners when key. This material looks the same key or not.
  func backdrop(_ frame: NSRect) -> Scrim {
    let vev = NSVisualEffectView(frame: frame)
    vev.material = .popover
    vev.state = .active
    vev.wantsLayer = true
    vev.layer?.cornerRadius = 16
    vev.layer?.masksToBounds = true
    vev.autoresizingMask = [.width, .height]
    let scrim = Scrim(frame: frame)
    scrim.autoresizingMask = [.width, .height]
    vev.addSubview(scrim)
    panel.contentView = vev
    self.scrim = scrim
    return scrim
  }

  @objc func muteClicked() { mute("toggle-mute") }
  @objc func advancedToggled() {
    showAdvanced.toggle()
    buildContent()
  }

  @objc func toggled(_ s: NSSwitch) {
    denoise = s.state == .on
    reconcile()
  }
  @objc func micPicked(_ p: NSPopUpButton) {
    input = p.selectedItem?.representedObject as? String ?? ""
    reconcile()
  }
  @objc func modelPicked(_ p: NSPopUpButton) {
    model = p.selectedItem?.representedObject as? String ?? "dfn"
    reconcile()
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
    _ = valueLabel("", meterText)
    updateMeter()
    return NSStackView(views: [meter, meterText])
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
    let s = focusable("strength", NSSlider(
      value: min(mix, top), minValue: 0, maxValue: top, target: self,
      action: #selector(mixChanged(_:))))
    s.isContinuous = false
    let text = !dfn ? "\(Int(mix * 100))%" : mix >= top ? "Max" : "\(Int(mix * 100)) dB"
    return NSStackView(views: [s, valueLabel(text)])
  }

  func valueLabel(_ s: String, _ l: NSTextField = NSTextField(labelWithString: "")) -> NSTextField {
    l.stringValue = s
    l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    l.textColor = .secondaryLabelColor
    l.alignment = .right
    if l.constraints.isEmpty { l.widthAnchor.constraint(equalToConstant: 44).isActive = true }
    return l
  }

  func gateRow() -> NSView {
    let s = focusable("gate", NSSlider(
      value: gate, minValue: GATE_OFF, maxValue: -10, target: self,
      action: #selector(gateChanged(_:))))
    s.isContinuous = true  // the gate is live: no restart, so track the drag
    return NSStackView(views: [s, valueLabel(gate > GATE_OFF ? "\(Int(gate)) dB" : "Off", gateText)])
  }

  @objc func gateChanged(_ s: NSSlider) {
    gate = s.doubleValue.rounded()
    gateText.stringValue = gate > GATE_OFF ? "\(Int(gate)) dB" : "Off"
    meter.warningValue = meterWarning
  }
  // The box reads "Keep the mic open", the inverse of `auto`.
  @objc func autoToggled(_ b: NSButton) {
    auto = b.state == .off
    reconcile()
  }
  @objc func mixChanged(_ s: NSSlider) {
    mix = (s.doubleValue * 100).rounded() / 100
    deepFilter?.limitDB = Float(mix * 100)  // live; reconcile() only restarts arnndn
    reconcile()
  }
}
