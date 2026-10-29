import AppKit

// `virtual-headset screenshot <dir>`: the real panel in each state the docs show,
// with sample values, as <dir>/<state>.png (scripts/screenshots.mjs). screencapture
// only captures windows on screen, so each state flashes in the screen's corner.
func screenshots(to dir: String) {
  let c = Controller(live: false)
  c.defaults.removePersistentDomain(forName: "com.github.virtual-headset.screenshot")
  c.panel.appearance = NSAppearance(named: .darkAqua)
  for (name, call, denoise, status, level, advanced, focus) in [
    ("live", "unmuted", true, "Using AirPods Pro", -24.0, false, nil),
    ("muted", "muted", true, "Mic released while the call is muted", nil, false, nil),
    ("no-call", "none", false, "Standby — opens when an app uses it", nil, false, nil),
    ("advanced", "none", true, "Standby — opens when an app uses it", nil, true, nil),
    ("keyboard", "unmuted", true, "Using AirPods Pro", -24.0, false, "strength"),
  ] {
    c.focusID = focus
    c.keyboardActive = focus != nil
    c.hidCall = call
    c.denoise = denoise
    c.status = status
    c.shownLevel = level
    c.showAdvanced = advanced
    c.buildContent()
    c.panel.setFrameOrigin(NSPoint(x: 20, y: 60))
    c.panel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(c.panel.windowNumber)", "\(dir)/\(name).png"]
    try? p.run()
    p.waitUntilExit()
    c.panel.orderOut(nil)
  }
}
