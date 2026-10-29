import AppKit

// MARK: Backdrop

// Translucent wash between the frosted backdrop and the controls, so text stays
// readable over a bright window behind the panel. A CGColor is a snapshot, so
// re-resolve it whenever the system flips Light/Dark.
final class Scrim: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 16
    layer?.masksToBounds = true
    apply()
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() { apply() }

  private func apply() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor.black : .white).withAlphaComponent(0.4).cgColor
  }
}
