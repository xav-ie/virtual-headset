import AppKit

// MARK: Keyboard

// A popup that takes the keyboard while it's open: as a plain non-activating panel
// it never became key, so keys went to the app behind it. Key presses reach `onKey`
// first; a click hands control back to the mouse (`onClick`).
final class PopupPanel: NSPanel {
  var onKey: ((NSEvent) -> Bool)?
  var onClick: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, onKey?(event) == true { return }
    if event.type == .leftMouseDown { onClick?() }
    super.sendEvent(event)
  }
}

// The keyboard focus ring: a 2 pt outline 4 pt outside the focused control, in the
// label color (Tetherbug's :focus-visible ring). Drawn by us, because AppKit only
// lets buttons, popups and sliders take focus with macOS's Keyboard navigation
// setting on; never hit-tested.
final class FocusRing: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.borderWidth = 2
    isHidden = true
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func updateLayer() { layer?.borderColor = NSColor.labelColor.cgColor }
  override var wantsUpdateLayer: Bool { true }

  func show(around view: NSView, in container: NSView) {
    let r = view.convert(view.bounds, to: container).insetBy(dx: -4, dy: -4)
    frame = r
    layer?.cornerRadius = min(r.height / 2, 10)
    isHidden = false
    needsDisplay = true
  }
}

extension Controller {
  // Registers a control for keyboard navigation, in the order the panel is built.
  @discardableResult
  func focusable<V: NSView>(_ id: String, _ view: V) -> V {
    focusables.append((id, view))
    return view
  }

  var focused: NSView? { focusables.first { $0.id == focusID }?.view }

  // Tab / Shift-Tab and the up/down arrows move focus; Space / Return activate;
  // left/right nudge a slider; Escape and ⌘W close, like any popup.
  func key(_ e: NSEvent) -> Bool {
    let shift = e.modifierFlags.contains(.shift)
    switch e.keyCode {
    case 53: closePanel()  // Escape
    case 13 where e.modifierFlags.contains(.command): closePanel()  // ⌘W
    case 48: moveFocus(shift ? -1 : 1)  // Tab
    case 125: moveFocus(1)  // down
    case 126: moveFocus(-1)  // up
    case 49, 36, 76:  // Space, Return, Enter
      guard keyboardActive, let v = focused else { return false }
      activate(v)
    case 123, 124:  // left, right
      guard keyboardActive, let s = focused as? NSSlider else { return false }
      s.doubleValue += (s.maxValue - s.minValue) / 20 * (e.keyCode == 124 ? 1 : -1)
      s.sendAction(s.action, to: s.target)
    default: return false
    }
    return true
  }

  // Reading order on screen, top to bottom, then left to right within a row (as
  // Tetherbug orders focus): the order controls are built in differs, e.g. the
  // call row's Mute button is made after the mic popup.
  func moveFocus(_ step: Int) {
    guard let container = ring.superview else { return }
    let frame = { (v: NSView) in v.convert(v.bounds, to: container) }
    let live = focusables.filter { ($0.view as? NSControl)?.isEnabled ?? true }.sorted { a, b in
      let fa = frame(a.view), fb = frame(b.view)
      return abs(fa.midY - fb.midY) < 6 ? fa.minX < fb.minX : fa.midY > fb.midY
    }
    guard !live.isEmpty else { return }
    if keyboardActive, let i = live.firstIndex(where: { $0.id == focusID }) {
      focusID = live[(i + step + live.count) % live.count].id
    } else {
      focusID = (step > 0 ? live.first : live.last)?.id
    }
    keyboardActive = true
    showRing()
  }

  func activate(_ v: NSView) {
    switch v {
    case let s as NSSwitch:
      s.state = s.state == .on ? .off : .on
      s.sendAction(s.action, to: s.target)
    case let c as NSControl: c.performClick(nil)  // buttons, checkboxes, popups
    default: break
    }
  }

  func showRing() {
    guard keyboardActive, let v = focused, let container = ring.superview else {
      ring.isHidden = true
      return
    }
    container.layoutSubtreeIfNeeded()
    ring.show(around: v, in: container)
    NSAccessibility.post(element: v, notification: .focusedUIElementChanged)
  }
}
