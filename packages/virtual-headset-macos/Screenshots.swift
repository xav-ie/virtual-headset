import AppKit
import BarPanels

// `virtual-headset screenshot <dir>`: the real panel in each state the docs show,
// with sample values, as <dir>/<state>.png (scripts/screenshots.mjs). screencapture
// only captures windows on screen, so each state flashes in the screen's corner.
//
// The panel is glass, which shows what's behind it: captured on its own it has
// nothing there and comes out flat black, its edge lost on a dark page. So it's
// shown over the README's mock desktop, captured with that, and cut back out
// along its rounded corners.
func screenshots(to dir: String) {
  let c = Controller(live: false)
  c.defaults.removePersistentDomain(forName: "com.github.virtual-headset.screenshot")
  c.panel.appearance = NSAppearance(named: .darkAqua)
  let backdrop = NSWindow(
    contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
  backdrop.level = NSWindow.Level(c.panel.level.rawValue - 1)
  backdrop.contentView = Desktop()
  for (name, call, denoise, status, level, advanced, focus) in [
    ("live", "unmuted", true, "Using AirPods Pro", -24.0, false, nil),
    ("muted", "muted", true, "Mic released while the call is muted", nil, false, nil),
    ("no-call", "none", false, "Standby — opens when an app uses it", nil, false, nil),
    ("advanced", "none", true, "Standby — opens when an app uses it", nil, true, nil),
    ("keyboard", "unmuted", true, "Using AirPods Pro", -24.0, false, "Strength"),
  ] {
    c.hidCall = call
    c.denoise = denoise
    c.status = status
    c.shownLevel = level
    c.showAdvanced = advanced
    c.buildContent()
    // Keyboard focus on the labelled field's control, as if reached with Tab.
    func find(_ v: NSView) -> NSView? {
      v.identifier?.rawValue == focus ? v : v.subviews.lazy.compactMap(find).first
    }
    let field = focus.flatMap { _ in c.panel.contentView.flatMap(find) }
    c.setKeyboardFocus(field?.subviews.first { $0 is NSSlider })
    c.panel.setFrameOrigin(NSPoint(x: 20, y: 60))
    let frame = c.panel.frame
    backdrop.setFrame(frame.insetBy(dx: -40, dy: -40), display: true)
    backdrop.orderFrontRegardless()
    c.panel.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    // screencapture's -R is in points from the top left of the main screen.
    let top = NSScreen.screens[0].frame.maxY - frame.maxY
    let path = "\(dir)/\(name).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = [
      "-x", "-R", "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", path,
    ]
    try? p.run()
    p.waitUntilExit()
    roundCorners(path, radius: PANEL_RADIUS * c.panel.backingScaleFactor)
    c.panel.orderOut(nil)
    backdrop.orderOut(nil)
  }
  // docs/macos.md shows these three side by side in a table, whose cells
  // GitHub centers vertically: as tall as the tallest, they line up at the top.
  padToTallest(["live", "muted", "no-call"].map { "\(dir)/\($0).png" })
}

// Extend each image downward with transparency to the tallest one's height.
func padToTallest(_ paths: [String]) {
  let images = paths.map { path -> CGImage? in
    CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
      .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
  }
  let height = images.compactMap { $0?.height }.max() ?? 0
  for (path, image) in zip(paths, images) {
    guard let image, image.height < height else { continue }
    writePNG(path, width: image.width, height: height) { ctx in
      // CoreGraphics' origin is the bottom left: the image goes at the top.
      ctx.draw(
        image,
        in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
    }
  }
}

// Draw a transparent width × height canvas and write it to `path` as a PNG.
func writePNG(_ path: String, width: Int, height: Int, _ draw: (CGContext) -> Void) {
  guard
    let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return }
  draw(ctx)
  guard let out = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
  else { return }
  CGImageDestinationAddImage(dest, out, nil)
  CGImageDestinationFinalize(dest)
}

// The mock desktop's gradient (scripts/screenshots.mjs), so the panel's glass
// looks the same in its own screenshots as in the README's.
final class Desktop: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSGradient(
      colors: [
        NSColor(srgbRed: 0x3a / 255, green: 0x41 / 255, blue: 0x57 / 255, alpha: 1),
        NSColor(srgbRed: 0x17 / 255, green: 0x1a / 255, blue: 0x22 / 255, alpha: 1),
      ])?.draw(in: bounds, relativeCenterPosition: NSPoint(x: -0.6, y: 0.8))
  }
}

// Make everything outside the panel's rounded rectangle transparent.
func roundCorners(_ path: String, radius: CGFloat) {
  guard
    let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
      .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
  else { return }
  writePNG(path, width: image.width, height: image.height) { ctx in
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    ctx.addPath(
      CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.draw(image, in: rect)
  }
}
