import Foundation
import os

// DeepFilterNet's LADSPA plugin hosted in-process. Through ffmpeg it only ever saw
// 4096-sample (~85 ms) packets — the raw-PCM pipe demuxer's fixed ~10 packets/s —
// so audio reached BlackHole in lumps (crunch + lag). Called per capture buffer
// here, run() just swaps buffers with the plugin's worker thread (~0.01 ms) and
// adds ~20 ms of algorithmic delay. The attenuation limit is a live control port.
final class DeepFilter {
  let d: LADSPA_Descriptor
  let h: LADSPA_Handle
  static let cap = 4096
  let inBuf = UnsafeMutablePointer<Float>.allocate(capacity: DeepFilter.cap)
  let outBuf = UnsafeMutablePointer<Float>.allocate(capacity: DeepFilter.cap)
  // Attenuation limit, min/max-ERB/max-DF thresholds, min buffer, post-filter beta:
  // the plugin's own defaults, as ffmpeg's ladspa filter would have set them.
  let ctl = UnsafeMutablePointer<Float>.allocate(capacity: 6)

  init?(limitDB: Float) {
    guard let lib = dlopen(DFN_LADSPA, RTLD_NOW), let sym = dlsym(lib, "ladspa_descriptor"),
      let dp = unsafeBitCast(sym, to: LADSPA_Descriptor_Function.self)(0),
      let h = dp.pointee.instantiate(dp, 48000)
    else { return nil }
    d = dp.pointee
    self.h = h
    for (i, v) in [limitDB, -15, 35, 35, 0, 0].enumerated() { ctl[i] = v }
    d.connect_port(h, 0, inBuf)
    d.connect_port(h, 1, outBuf)
    for i in 0..<6 { d.connect_port(h, UInt(2 + i), ctl + i) }
    d.activate?(h)
  }

  var limitDB: Float {
    get { ctl[0] }
    set { ctl[0] = newValue }  // read by the plugin on its next run(); a benign race
  }

  // One instance outlives each capture (see Controller.deepFilter), so a stopping
  // capture's last buffers can overlap the next one's first: serialize run().
  let lock = OSAllocatedUnfairLock()

  func process(_ x: UnsafeMutableBufferPointer<Float>) {
    lock.withLock {
      var i = 0
      while i < x.count {
        let n = min(DeepFilter.cap, x.count - i)
        inBuf.update(from: x.baseAddress! + i, count: n)
        d.run(h, UInt(n))
        (x.baseAddress! + i).update(from: outBuf, count: n)
        i += n
      }
    }
  }

  deinit {
    d.deactivate?(h)
    d.cleanup(h)
    inBuf.deallocate()
    outBuf.deallocate()
    ctl.deallocate()
  }
}
