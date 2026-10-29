import AVFoundation
import os

// Plays denoised audio into BlackHole through our own HAL output unit, so the only
// queue between the denoiser and the call app is this ring — and it's capped.
// ffmpeg's audiotoolbox writer used an AudioQueue that enqueued everything it was
// handed, so the backlog that piles up while DeepFilterNet loads (~1–3 s) played
// out at real time forever as permanent lag. Here anything beyond MAX is dropped
// down to KEEP; that also absorbs mic-vs-BlackHole clock drift on long calls.
final class BlackHoleOut {
  // Jitter buffer: play only once `prime` is queued and re-prime after running dry
  // (else every late burst is a dropout = crackle); past `max`, drop back to `keep`.
  // Sized to the producer's burst: ~10 ms for in-process engines, 4096 samples
  // (~85 ms) for anything coming out of ffmpeg's raw-PCM pipe.
  let prime: Int
  let keep: Int
  let max: Int
  var primed = false
  var unit: AudioUnit?
  let lock = OSAllocatedUnfairLock()
  var ring = [Float](repeating: 0, count: 48000)
  var r = 0
  var fill = 0

  init?(device: AudioObjectID, burst: Int) {
    prime = burst + 960
    keep = burst + 1920
    max = 2 * burst + 4800
    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    var u: AudioUnit?
    guard let comp = AudioComponentFindNext(nil, &desc), AudioComponentInstanceNew(comp, &u) == noErr,
      let unit = u
    else { return nil }
    self.unit = unit
    func set<T>(_ p: AudioUnitPropertyID, _ scope: AudioUnitScope, _ v: T) -> Bool {
      var v = v
      return AudioUnitSetProperty(unit, p, scope, 0, &v, UInt32(MemoryLayout<T>.size)) == noErr
    }
    // Stereo out (the driver is 2ch); the same mono sample goes to both channels.
    let fmt = AudioStreamBasicDescription(
      mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
      mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
      mReserved: 0)
    let me = Unmanaged.passUnretained(self).toOpaque()
    guard set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, device),
      set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, fmt),
      set(
        kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
        AURenderCallbackStruct(
          inputProc: { ref, _, _, _, n, data in
            let me = Unmanaged<BlackHoleOut>.fromOpaque(ref).takeUnretainedValue()
            let out = UnsafeMutableAudioBufferListPointer(data!)[0].mData!
              .assumingMemoryBound(to: Float.self)
            me.render(out, Int(n))
            return noErr
          }, inputProcRefCon: me)),
      AudioUnitInitialize(unit) == noErr, AudioOutputUnitStart(unit) == noErr
    else {
      AudioComponentInstanceDispose(unit)
      return nil
    }
  }

  // Drift control: the mic (e.g. EarPods' own USB clock) and BlackHole tick at
  // slightly different rates — measured 0.1–0.25% — so a fixed-rate reader slowly
  // gains backlog until `max` chops it (a glitch, with latency saw-toothing up to
  // ~140 ms). Instead read at 1 ± ≤0.5%, steered by the smoothed queue depth toward
  // `prime`, interpolating linearly between samples. Inaudible; latency holds.
  var pos = 0.0  // fractional read position past `r`
  var avg = 0.0  // smoothed fill, so per-burst jitter doesn't wobble the rate

  func render(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
    lock.withLock {
      if !primed {
        primed = fill >= prime
        avg = Double(fill)
      }
      avg += (Double(fill) - avg) * min(1, Double(n) / 24000)  // ~0.5 s time constant
      let ratio = 1 + Swift.max(-0.005, Swift.min(0.005, (avg - Double(prime)) * 1e-5))
      for i in 0..<n {
        var v: Float = 0
        if primed, fill >= 3 {
          let a = ring[r]
          v = a + (ring[(r + 1) % ring.count] - a) * Float(pos)
          pos += ratio
          let step = Int(pos)
          pos -= Double(step)
          r = (r + step) % ring.count
          fill -= step
        } else {
          primed = false
        }
        out[2 * i] = v
        out[2 * i + 1] = v
      }
    }
  }

  func push(_ s: UnsafeBufferPointer<Float>) {
    let dropped = lock.withLock { () -> Int in
      for x in s {
        ring[(r + fill) % ring.count] = x
        if fill < ring.count { fill += 1 } else { r = (r + 1) % ring.count }
      }
      guard fill > max else { return 0 }
      let d = fill - keep
      r = (r + d) % ring.count
      fill = keep
      return d
    }
    if dropped > 2400 {  // only worth noting past 50 ms (startup backlog, drift)
      FileHandle.standardError.write(Data("dropped \(dropped / 48) ms of backlog\n".utf8))
    }
  }

  func stop() {
    guard let unit else { return }
    AudioOutputUnitStop(unit)
    AudioComponentInstanceDispose(unit)
    self.unit = nil
  }
}
