import CoreAudio
import Foundation

// MARK: Engine

struct Failure: Error { let msg: String }

struct Config: Equatable {
  let input: String  // display name
  let uid: String  // CoreAudio UID == AVCaptureDevice.uniqueID
  let outID: AudioObjectID
  let denoise: Bool
  let model: String
  let mix: Double
}

// Post-denoise noise gate, in Swift so threshold changes land on the next buffer
// (ffmpeg here can't take live commands). The detector is a ~10 ms RMS envelope —
// the same quantity the Level meter shows — so you can read the threshold off it.
struct Gate {
  static let envC = Float(exp(-1 / (0.010 * 48000)))
  static let openC = Float(exp(-1 / (0.003 * 48000)))
  static let closeC = Float(exp(-1 / (0.080 * 48000)))  // ~0.3 s to fully shut
  static let shut: Float = 0.01  // -40 dB rather than hard mute, so it doesn't click
  var power: Float = 0
  var gain: Float = 1

  // Gates in place; returns the chunk's summed squares (pre-gate) for the meter.
  mutating func process(_ s: UnsafeMutableBufferPointer<Float>, thresholdDB: Double) -> Float {
    let thr = thresholdDB > GATE_OFF ? Float(pow(10, thresholdDB / 10)) : 0  // power
    var sum: Float = 0
    for i in s.indices {
      let x2 = s[i] * s[i]
      sum += x2
      power = x2 + (power - x2) * Gate.envC
      let target: Float = power >= thr ? 1 : Gate.shut
      gain = target + (gain - target) * (target > gain ? Gate.openC : Gate.closeC)
      s[i] *= gain
    }
    return sum
  }
}

// The stage after denoising, shared by every engine: live Gate, Level meter, out.
final class Post {
  var gate = Gate()
  var sum: Float = 0
  var n = 0
  let out: BlackHoleOut
  let threshold: () -> Double
  let level: (Double) -> Void

  init(out: BlackHoleOut, threshold: @escaping () -> Double, level: @escaping (Double) -> Void) {
    self.out = out
    self.threshold = threshold
    self.level = level
  }

  func feed(_ x: UnsafeMutableBufferPointer<Float>) {
    sum += gate.process(x, thresholdDB: threshold())
    n += x.count
    if n >= 4800 {  // ~100 ms
      level(10 * log10(Double(sum) / Double(n)))
      sum = 0
      n = 0
    }
    out.push(UnsafeBufferPointer(x))
  }
}
