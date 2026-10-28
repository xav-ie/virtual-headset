// virtual-headset (macOS) — one resident agent.
//
// Forwards the real mic into Virtual_Headset_Microphone, a renamed BlackHole
// (packages/virtual-headset-driver) the call app picks as its mic, optionally
// denoising it on the way (DeepFilterNet in-process, or RNNoise via ffmpeg). It
// also presents the Virtual_Headset HID telephony device whose mute button and
// LEDs the call app syncs with. While the call is muted the real mic is released,
// so a Bluetooth headset drops back from mono HFP to stereo A2DP.
//
// The sketchybar `virtual_headset` item OWNS the bar icon and runs
// `virtual-headset panel <x>` on click, which posts TOGGLE so we open the settings
// panel under it. We only PUBLISH state to ~/.cache/virtual-headset (see
// publish()) + a CHANGED notification the item subscribes to.
//
// The default-input and device-list CoreAudio listeners restart the pipeline
// whenever the mic it should read (or the BlackHole device) changes — that's what
// makes "Default" follow AirPods/EarPods switches.

import AVFoundation
import AppKit
import CoreAudio
import IOKit.hid
import os

let TOGGLE = Notification.Name("com.github.virtual-headset.toggle-panel")
let CHANGED = Notification.Name("com.github.virtual-headset.changed")
let MUTE = Notification.Name("com.github.virtual-headset.mute")
let OUT_NAME = "Virtual_Headset_Microphone"
let OUT_UID = "Virtual_Headset_Microphone_UID"
// State for bar integrations (see publish()).
let CACHE = ("~/.cache/virtual-headset" as NSString).expandingTildeInPath
let GATE_OFF = -70.0

func post(_ name: Notification.Name, _ object: String?) {
  DistributedNotificationCenter.default().postNotificationName(
    name, object: object, userInfo: nil, deliverImmediately: true)
}

// CLI: `virtual-headset panel [x]` asks the running agent to toggle its panel;
// `virtual-headset mute|unmute|toggle-mute` presses the headset's mute button.
switch CommandLine.arguments.dropFirst().first {
case "panel":
  post(TOGGLE, CommandLine.arguments.dropFirst(2).first)
  exit(0)
case let cmd? where ["mute", "unmute", "toggle-mute"].contains(cmd):
  post(MUTE, cmd)
  exit(0)
default:
  break
}

// "dfn" is DeepFilterNet 3 (LADSPA): far stronger on non-stationary noise like
// music, ~9% of a core. The rest are RNNoise via arnndn, GregorR/rnnoise-models:
// expected signal × expected noise. "Recording" noise = mic hiss/room tone;
// "general" = everything else (keyboard, fans, street).
let MODELS: [(key: String, label: String)] = [
  ("dfn", "DeepFilterNet 3"),
  ("lq", "RNNoise: voice, everyday noise"),
  ("bd", "RNNoise: voice, mic/room noise"),
  ("sh", "RNNoise: speech only, mic/room noise"),
  ("mp", "RNNoise: any sound, everyday noise"),
  ("cb", "RNNoise: any sound, mic/room noise"),
]

// MARK: CoreAudio

let SYSTEM = AudioObjectID(kAudioObjectSystemObject)

func addr(
  _ sel: AudioObjectPropertySelector,
  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
)
  -> AudioObjectPropertyAddress
{
  AudioObjectPropertyAddress(
    mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func ids(
  _ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
)
  -> [AudioObjectID]
{
  var a = addr(sel, scope)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr else { return [] }
  var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
  guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
  return out
}

func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
  var a = addr(sel)
  var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  var s: Unmanaged<CFString>?
  guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let s else { return "" }
  return s.takeRetainedValue() as String
}

func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
  var a = addr(sel)
  var v: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
  return v
}

// Is any OTHER process recording from this device right now? (macOS 14.2+ process
// objects.) Our own ffmpeg only plays INTO BlackHole, so it never counts.
func someoneRecords(from device: AudioObjectID) -> Bool {
  ids(SYSTEM, kAudioHardwarePropertyProcessObjectList).contains { p in
    u32(p, kAudioProcessPropertyPID) != UInt32(getpid())
      && u32(p, kAudioProcessPropertyIsRunningInput) != 0
      && ids(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput).contains(device)
  }
}

struct Device {
  let id: AudioObjectID
  let name: String
  let uid: String
  let isInput: Bool
}

func devices() -> [Device] {
  ids(SYSTEM, kAudioHardwarePropertyDevices).map { id in
    Device(
      id: id, name: string(id, kAudioObjectPropertyName),
      uid: string(id, kAudioDevicePropertyDeviceUID),
      isInput: !ids(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty)
  }
}

func defaultInput() -> AudioObjectID {
  ids(SYSTEM, kAudioHardwarePropertyDefaultInputDevice).first ?? 0
}

// MARK: Headset

// Virtual USB telephony headset with the Linux daemon's HID layout, created from
// userspace via IOHIDUserDevice. That needs the com.apple.developer.hid.virtual.device
// entitlement, which an ad-hoc signature only satisfies with AMFI relaxed
// (amfi_get_out_of_my_way=1). Zoom web pairs it with the selected mic only when the
// mic's label contains our product name — hence Virtual_Headset_Microphone.
//   Report 1 (in):  hook switch (bit 0) + mute toggle pulse (bit 1)
//   Report 2 (out): mute (bit 0) / off-hook (bit 1) / ring (bit 2) LEDs
//   Report 3 (out): command 1 = mute, 2 = unmute, 3 = toggle
final class Headset {
  static let descriptor: [UInt8] = [
    0x05, 0x0B, 0x09, 0x05, 0xA1, 0x01,
    0x85, 0x01, 0x15, 0x00, 0x25, 0x01, 0x09, 0x20, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
    0x09, 0x2F, 0x75, 0x01, 0x95, 0x01, 0x81, 0x06, 0x75, 0x06, 0x95, 0x01, 0x81, 0x03,
    0x85, 0x02, 0x05, 0x08, 0x09, 0x09, 0x75, 0x01, 0x95, 0x01, 0x91, 0x02,
    0x09, 0x17, 0x75, 0x01, 0x95, 0x01, 0x91, 0x02, 0x09, 0x18, 0x75, 0x01, 0x95, 0x01, 0x91, 0x02,
    0x75, 0x05, 0x95, 0x01, 0x91, 0x03,
    0x85, 0x03, 0x05, 0x0B, 0x09, 0x2F, 0x15, 0x00, 0x25, 0x03, 0x75, 0x08, 0x95, 0x01, 0x91, 0x02,
    0xC0,
  ]
  let device: IOHIDUserDevice
  let queue = DispatchQueue(label: "virtual-headset.headset")

  // `led` and `command` are called on the main queue.
  init?(led: @escaping (_ muted: Bool, _ offHook: Bool) -> Void, command: @escaping (UInt8) -> Void) {
    let props: [String: Any] = [
      kIOHIDReportDescriptorKey: Data(Headset.descriptor),
      // Jabra Evolve2 65: call apps special-case known headset vendors.
      kIOHIDVendorIDKey: 0x0b0e,
      kIOHIDProductIDKey: 0x245e,
      kIOHIDProductKey: "Virtual_Headset",
      kIOHIDManufacturerKey: "virtual-headset",
      kIOHIDTransportKey: "USB",
      kIOHIDSerialNumberKey: "virtual-headset",
    ]
    guard let device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, props as CFDictionary, 0)
    else { return nil }
    self.device = device
    IOHIDUserDeviceRegisterSetReportBlock(device) { _, id, bytes, len in
      let data = Array(UnsafeBufferPointer(start: bytes, count: len))
      // Report bytes may or may not lead with the report id.
      guard let value = data.count > 1 && data[0] == UInt8(id) ? data.last : data.first else {
        return kIOReturnSuccess
      }
      DispatchQueue.main.async {
        switch id {
        case 2: led(value & 0x01 != 0, value & 0x02 != 0)
        case 3: command(value)
        default: break
        }
      }
      return kIOReturnSuccess
    }
    IOHIDUserDeviceRegisterGetReportBlock(device) { _, _, _, _ in kIOReturnSuccess }
    IOHIDUserDeviceSetDispatchQueue(device, queue)
    IOHIDUserDeviceActivate(device)
    send([0x01, 0x01])  // off-hook, mute released
  }

  // A 0→1→0 pulse on the relative mute bit: the call app toggles its own mute.
  func pressMute() {
    send([0x01, 0x03])
    queue.asyncAfter(deadline: .now() + 0.05) { self.send([0x01, 0x01]) }
  }

  private func send(_ report: [UInt8]) {
    var r = report
    IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), &r, r.count)
  }
}

// MARK: Glass

// Translucent wash between the glass and the controls: .clear glass alone leaves
// text unreadable over a bright window behind the panel. A CGColor is a snapshot,
// so re-resolve it (and re-soften the glass, whose material rebuilds) whenever the
// system flips Light/Dark.
final class Scrim: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 16
    layer?.masksToBounds = true
    apply()
  }
  required init?(coder: NSCoder) { fatalError() }

  override func viewDidChangeEffectiveAppearance() {
    apply()
    guard let glass = window?.contentView else { return }
    DispatchQueue.main.async { reduceGlassBlur(glass) }
  }

  private func apply() {
    let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    layer?.backgroundColor = (dark ? NSColor.black : .white).withAlphaComponent(0.4).cgColor
  }
}

// Stock glass blurs the backdrop at inputBlurRadius 10, smearing whatever is
// behind the panel into mush. Nothing on NSGlassEffectView exposes the radius, so
// rebuild the private `glassBackground` CAFilter with a smaller one, copying every
// other input. Mutating the committed filter does nothing (it's already with the
// render server) — it must be built fresh and reassigned.
// ponytail: private CoreAnimation API; a macOS update can rename the filter or its
// inputs. Fails soft — no filter found means stock blur, nothing worse.
func reduceGlassBlur(_ view: NSView, radius: Double = 3) {
  guard let root = view.layer, let filterClass = NSClassFromString("CAFilter") as? NSObject.Type
  else { return }
  func visit(_ layer: CALayer) {
    defer { layer.sublayers?.forEach(visit) }
    guard String(describing: type(of: layer)) == "CABackdropLayer",
      let filters = (layer as NSObject).value(forKey: "filters") as? [NSObject]
    else { return }
    let rebuilt = filters.map { filter -> NSObject in
      guard "\(filter)" == "glassBackground",
        let fresh = (filterClass as AnyObject).perform(
          NSSelectorFromString("filterWithName:"), with: "glassBackground")?
          .takeUnretainedValue() as? NSObject,
        let inputs = filter.perform(NSSelectorFromString("inputKeys"))?
          .takeUnretainedValue() as? [String]
      else { return filter }
      for key in inputs where key != "inputBlurRadius" {
        if let v = filter.value(forKey: key) { fresh.setValue(v, forKey: key) }
      }
      fresh.setValue(radius, forKey: "inputBlurRadius")
      return fresh
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    (layer as NSObject).setValue(rebuilt, forKey: "filters")
    CATransaction.commit()
  }
  visit(root)
}

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

// Mic capture in-process: ffmpeg's own avfoundation demuxer dropped over half the
// samples (an 8 s take held ~3.5 s, playing back sped up). AVCaptureSession hands
// us 48 kHz mono float32, which we pipe into ffmpeg's stdin — and tee into a take
// while recording, so the A/B test hears exactly what the live chain gets.
// Mic capture via AVCaptureSession on the chosen device, as 48 kHz mono float32.
final class Capture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  // startRunning/stopRunning block until the device is up/down — seconds while a
  // Bluetooth headset switches profile — so they run here, off the main thread.
  // One serial queue for every session keeps a stop ordered before the next start.
  static let sessionQueue = DispatchQueue(label: "virtual-headset.session")
  var session: AVCaptureSession?
  let queue = DispatchQueue(label: "virtual-headset.capture")
  let sink: (Data) -> Void
  // Touched only on `queue`.
  var take: Data?
  var takeBytes = 0
  var takeDone: ((Data) -> Void)?

  init?(uid: String, sink: @escaping (Data) -> Void) {
    self.sink = sink
    super.init()
    let session = AVCaptureSession()
    self.session = session
    guard let dev = AVCaptureDevice(uniqueID: uid),
      let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input)
    else { return nil }
    session.addInput(input)
    let out = AVCaptureAudioDataOutput()
    out.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    out.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(out) else { return nil }
    session.addOutput(out)
    Capture.sessionQueue.async { session.startRunning() }
  }

  func record(seconds: Double, done: @escaping (Data) -> Void) {
    queue.async {
      self.take = Data()
      self.takeBytes = Int(48000 * 4 * seconds)
      self.takeDone = done
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput buf: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let block = CMSampleBufferGetDataBuffer(buf) else { return }
    var data = Data(count: CMBlockBufferGetDataLength(block))
    data.withUnsafeMutableBytes {
      _ = CMBlockBufferCopyDataBytes(
        block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
    }
    deliver(data)
  }

  // On `queue`: feed the pipeline, and the take while recording.
  func deliver(_ data: Data) {
    sink(data)
    guard take != nil else { return }
    take!.append(data)
    if take!.count >= takeBytes, let done = takeDone {
      let t = take!
      take = nil
      DispatchQueue.main.async { done(t) }
    }
  }

  // Samples may still arrive until the queued stop lands; the sink tolerates that
  // (a stopped BlackHoleOut only fills its ring; a dead ffmpeg pipe throws, ignored).
  func stop() {
    guard let session else { return }
    Capture.sessionQueue.async { session.stopRunning() }
  }
}

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

  func process(_ x: UnsafeMutableBufferPointer<Float>) {
    var i = 0
    while i < x.count {
      let n = min(DeepFilter.cap, x.count - i)
      inBuf.update(from: x.baseAddress! + i, count: n)
      d.run(h, UInt(n))
      (x.baseAddress! + i).update(from: outBuf, count: n)
      i += n
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

final class Controller: NSObject, NSSoundDelegate {
  let defaults: UserDefaults
  // A screenshot controller only draws the panel: no devices, audio or listeners.
  let live: Bool
  // Overrides the meter for screenshots, where no mic is open.
  var shownLevel: Double?
  // Noise suppression on top of forwarding; off passes the mic through untouched.
  // Kept under the "enabled" key so existing settings carry over.
  var denoise: Bool {
    get { defaults.bool(forKey: "enabled") }
    set { defaults.set(newValue, forKey: "enabled") }
  }
  var input: String {  // "" = follow the system default input
    get { defaults.string(forKey: "input") ?? "" }
    set { defaults.set(newValue, forKey: "input") }
  }
  // Run only while some app records from Virtual_Headset_Microphone, so the
  // mic — and its privacy indicator — is idle the rest of the time.
  var auto: Bool {
    get { defaults.object(forKey: "auto") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "auto") }
  }
  var model: String {
    // Unknown keys (a removed engine, e.g. the old "apple") fall back to the default.
    get { defaults.string(forKey: "model").flatMap { m in MODELS.contains { $0.key == m } ? m : nil } ?? "dfn" }
    set { defaults.set(newValue, forKey: "model") }
  }
  var mix: Double {
    get { defaults.object(forKey: "mix") as? Double ?? 1 }
    set { defaults.set(newValue, forKey: "mix") }
  }
  // Noise gate threshold in dBFS after denoising; GATE_OFF disables it. A close
  // mic (EarPods) hears your voice far louder than room noise, so the gate mutes
  // the gaps between your words without touching them.
  var gate: Double {
    get { defaults.object(forKey: "gate") as? Double ?? GATE_OFF }
    set { defaults.set(newValue, forKey: "gate") }
  }

  var procs: [Process] = []  // the arnndn ffmpeg, when RNNoise is the engine
  var standby = false
  var headset: Headset?
  // The call app's LEDs: "none" (on-hook / never connected), "muted", "unmuted".
  // While muted the real mic is released (Bluetooth headsets go back to A2DP);
  // only the call app's LED reports change it.
  var call = "none"
  var callMuted: Bool { call == "muted" }
  var showAdvanced = false
  var glass: NSView?
  var scrim: Scrim?
  var capture: Capture?
  var bhOut: BlackHoleOut?
  var deepFilter: DeepFilter?
  var running: Config?
  var status = "Off"
  var reconcileScheduled = false
  // Live RMS (dBFS) of the denoised signal — what the gate compares against.
  var level = -Double.infinity
  let meter = NSLevelIndicator()
  let meterText = NSTextField(labelWithString: "")
  // A/B test: record the raw mic once, then render it through the CURRENT settings
  // on every "Denoised" play — so you can tweak the gate and re-listen to one take.
  var recording = false
  var sound: NSSound?
  var playing: String?  // key into `takes`
  let playhead = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  let playTime = NSTextField(labelWithString: "")
  let gateText = NSTextField(labelWithString: "")
  let takes = [
    "pcm": NSTemporaryDirectory() + "virtual-headset-raw.f32",
    "den": NSTemporaryDirectory() + "virtual-headset-den.f32",
    "raw": NSTemporaryDirectory() + "virtual-headset-raw.wav",
    "out": NSTemporaryDirectory() + "virtual-headset-out.wav",
  ]

  let panel = PopupPanel(
    contentRect: NSRect(x: 0, y: 0, width: Controller.width, height: 40),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  // Keyboard navigation, independent of macOS's setting (see FocusRing): the panel's
  // controls in reading order, rebuilt with it; focus is kept by id across rebuilds.
  var focusables: [(id: String, view: NSView)] = []
  var focusID: String?
  var keyboardActive = false
  let ring = FocusRing(frame: .zero)
  var clickMonitor: Any?
  var lastMonitorClose: Date?

  init(live: Bool = true) {
    self.live = live
    // Screenshots keep their settings in a throwaway domain, never the user's.
    defaults = live ? .standard : UserDefaults(suiteName: "com.github.virtual-headset.screenshot")!
    super.init()
    // Settings saved under the agent's previous bundle id carry over once.
    if live, defaults.object(forKey: "migrated") == nil,
      let old = UserDefaults(suiteName: "com.x.mic-denoise")
    {
      for k in ["enabled", "input", "auto", "model", "mix", "gate"] {
        if let v = old.object(forKey: k) { defaults.set(v, forKey: k) }
      }
      defaults.set(true, forKey: "migrated")
    }
    panel.level = .popUpMenu
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.setAccessibilityLabel("Virtual Headset")
    panel.onKey = { [weak self] e in self?.key(e) ?? false }
    panel.onClick = { [weak self] in
      self?.keyboardActive = false
      self?.ring.isHidden = true
    }
    guard live else { return }

    DistributedNotificationCenter.default().addObserver(forName: TOGGLE, object: nil, queue: .main)
    {
      [weak self] note in
      let x = (note.object as? String).flatMap(Double.init).map { CGFloat($0) }
      self?.togglePanel(anchorX: x)
    }
    DistributedNotificationCenter.default().addObserver(forName: MUTE, object: nil, queue: .main) {
      [weak self] note in
      self?.mute(note.object as? String)
    }
    headset = Headset(
      led: { [weak self] muted, offHook in
        self?.setCall(!offHook ? "none" : muted ? "muted" : "unmuted")
      },
      command: { [weak self] c in self?.mute([1: "mute", 2: "unmute", 3: "toggle-mute"][c]) })
    for sel in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
      var a = addr(sel)
      AudioObjectAddPropertyListenerBlock(SYSTEM, &a, .main) { [weak self] _, _ in
        self?.scheduleReconcile()
      }
    }
    // Builds before BlackHoleOut wrote via an ffmpeg audiotoolbox child; when launchd
    // replaces such an instance, that child is orphaned to ppid 1 and keeps writing
    // into BlackHole alongside us. Our own children never have ppid 1.
    let sweep = Process()
    sweep.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    sweep.arguments = ["-9", "-P", "1", "-f", "audiotoolbox -audio_device_index"]
    try? sweep.run()
    sweep.waitUntilExit()
    reconcile()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, self.panel.isVisible else { return }
      self.updateMeter()
      self.updatePlayhead()
    }
    // ponytail: 1 s poll of process objects; listen to kAudioProcessPropertyIsRunningInput
    // per process if start-up lag ever matters.
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, self.auto, !self.callMuted,
        let bh = devices().first(where: { $0.uid == OUT_UID })
      else { return }
      if someoneRecords(from: bh.id) == (self.capture == nil) { self.reconcile() }
    }
  }

  // Device changes arrive in bursts (plugging a headset fires several).
  func scheduleReconcile() {
    guard !reconcileScheduled else { return }
    reconcileScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      self?.reconcileScheduled = false
      self?.reconcile()
    }
  }

  // Resolve what ffmpeg should be doing right now, or why it can't.
  func desired() -> Result<Config, Failure> {
    let all = devices()
    guard let out = all.first(where: { $0.uid == OUT_UID }) else {
      return .failure(Failure(msg: "\(OUT_NAME) not installed"))
    }
    let mics = all.filter { $0.isInput && $0.uid != OUT_UID }
    // A picked mic that's unplugged falls back to the default rather than going silent.
    let mic =
      mics.first(where: { $0.name == input }) ?? mics.first(where: { $0.id == defaultInput() })
    guard let mic else {
      return .failure(Failure(msg: "No microphone available"))
    }
    return .success(
      Config(
        input: mic.name, uid: mic.uid, outID: out.id, denoise: denoise, model: model,
        // In-process engines apply strength live (no restart); only arnndn needs one.
        mix: denoise && model != "dfn" ? mix : 0))
  }

  func reconcile() {
    defer {
      publish()
      if panel.isVisible { buildContent() }
    }
    standby = false
    switch desired() {
    case .failure(let f):
      stop()
      status = f.msg
    case .success(let cfg):
      if callMuted {
        stop()
        status = "Mic released while the call is muted"
        return
      }
      if auto, let bh = devices().first(where: { $0.uid == OUT_UID }),
        !someoneRecords(from: bh.id)
      {
        stop()
        standby = true
        status = "Standby — opens when an app uses it"
        return
      }
      if cfg == running, capture != nil, procs.allSatisfy(\.isRunning) { return }
      stop()
      start(cfg)
    }
  }

  func ffmpeg(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: FFMPEG)
    p.arguments =
      // No `-fflags nobuffer`: with a pipe input it makes ffmpeg emit nothing at all.
      // No probing: the format is given, and by default ffmpeg buffers ~5 s of input
      // (analyzeduration) before opening the output — the real-time BlackHole writer
      // then plays that backlog forever, i.e. a permanent ~5 s lag.
      ["-hide_banner", "-loglevel", "warning", "-nostdin", "-flags", "low_delay"]
      + ["-probesize", "32", "-analyzeduration", "0"]
      + ["-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "pipe:0"] + args
    return p
  }

  // DeepFilterNet: mic → DeepFilter → Post → BlackHole, all in-process.
  // RNNoise (arnndn is ffmpeg-only): mic → ffmpeg pipe → Post → BlackHole, with a
  // jitter buffer sized for ffmpeg's ~85 ms output lumps.
  // Noise suppression off: mic → Post (ungated) → BlackHole.
  func start(_ cfg: Config) {
    let viaFFmpeg = cfg.denoise && cfg.model != "dfn"
    // AVCapture hands over ~557-frame (11.6 ms) buffers; ffmpeg's pipe output, 4096.
    guard let out = BlackHoleOut(device: cfg.outID, burst: viaFFmpeg ? 4096 : 560) else {
      status = "Can't open \(OUT_NAME) for output"
      return
    }
    bhOut = out
    let post = Post(
      out: out, threshold: { [weak self] in cfg.denoise ? self?.gate ?? GATE_OFF : GATE_OFF },
      level: { [weak self] db in DispatchQueue.main.async { self?.level = db } })

    let sink: (Data) -> Void
    if viaFFmpeg {
      let den = ffmpeg(
        ["-af", filters(cfg), "-f", "f32le", "-ar", "48000", "-ac", "1", "-flush_packets", "1",
         "pipe:1"])
      let pcm = Pipe()
      let mid = Pipe()
      den.standardInput = pcm
      den.standardOutput = mid
      var pending = Data()
      mid.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty else {
          h.readabilityHandler = nil  // EOF
          return
        }
        pending.append(data)
        let whole = pending.count / 4 * 4
        guard whole > 0 else { return }
        var chunk = Data(pending.prefix(whole))
        pending.removeFirst(whole)
        chunk.withUnsafeMutableBytes { post.feed($0.bindMemory(to: Float.self)) }
      }
      den.terminationHandler = { [weak self] dead in
        DispatchQueue.main.async {
          guard let self, self.procs.contains(dead) else { return }  // a deliberate stop()
          self.stop()
          self.status = "ffmpeg exited (\(dead.terminationStatus)), retrying…"
          self.publish()
          if self.panel.isVisible { self.buildContent() }
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reconcile() }
        }
      }
      do {
        try den.run()
      } catch {
        stop()
        status = "ffmpeg failed: \(error.localizedDescription)"
        return
      }
      procs = [den]
      let w = pcm.fileHandleForWriting
      sink = { try? w.write(contentsOf: $0) }  // throws (not SIGPIPE, ignored) once ffmpeg dies
    } else if !cfg.denoise {
      sink = { data in
        var chunk = data
        chunk.withUnsafeMutableBytes { post.feed($0.bindMemory(to: Float.self)) }
      }
    } else {
      guard let df = DeepFilter(limitDB: Float(mix * 100)) else {
        stop()
        status = "Can't load DeepFilterNet"
        return
      }
      deepFilter = df
      sink = { data in
        var chunk = data
        chunk.withUnsafeMutableBytes {
          let x = $0.bindMemory(to: Float.self)
          df.process(x)
          post.feed(x)
        }
      }
    }

    guard let c = Capture(uid: cfg.uid, sink: sink) else {
      stop()
      status = "Can't open \(cfg.input)"
      return
    }
    capture = c
    running = cfg
    status = "Using \(cfg.input)"
  }

  // Strength maps to arnndn's mix, or DeepFilterNet's attenuation limit (c0, 0–100 dB).
  func filters(_ cfg: Config) -> String {
    switch cfg.model {
    case "dfn":
      "aresample=48000,aformat=channel_layouts=mono,ladspa=f=\(DFN_LADSPA):p=deep_filter_mono:c=c0=\(Int(cfg.mix * 100))"
    default:
      "aresample=48000,arnndn=m=\(Bundle.main.resourcePath!)/models/\(cfg.model).rnnn:mix=\(cfg.mix)"
    }
  }

  func stop() {
    capture?.stop()
    capture = nil
    bhOut?.stop()
    bhOut = nil
    deepFilter = nil
    let dead = procs
    procs = []
    running = nil
    // SIGKILL, not terminate(): ffmpeg's graceful SIGTERM path hangs in the
    // audiotoolbox teardown, leaving stale writers summed into BlackHole. Live audio
    // has nothing to flush.
    for p in dead where p.isRunning { kill(p.processIdentifier, SIGKILL) }
  }

  // The press only asks; the call app's LED report is what changes `call`.
  func mute(_ cmd: String?) {
    guard call != "none" else { return nudge() }
    switch cmd {
    case "mute" where !callMuted, "unmute" where callMuted, "toggle-mute": headset?.pressMute()
    default: break
    }
  }

  // Nothing paired to mute: the bar item flashes on this marker, so a mute press
  // outside a call isn't silently dropped.
  func nudge() {
    try? "".write(toFile: "\(CACHE)/nudge", atomically: true, encoding: .utf8)
    post(CHANGED, nil)
  }

  func setCall(_ state: String) {
    guard state != call else { return }
    call = state
    reconcile()
  }

  func publish() {
    let dir = CACHE
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let state =
      callMuted
      ? "muted" : capture != nil ? (denoise ? "on" : "raw") : standby ? "standby" : "error"
    try? state.write(toFile: "\(dir)/state", atomically: true, encoding: .utf8)
    try? call.write(toFile: "\(dir)/call", atomically: true, encoding: .utf8)
    post(CHANGED, nil)
  }

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

  func moveFocus(_ step: Int) {
    let live = focusables.filter { ($0.view as? NSControl)?.isEnabled ?? true }
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
    // One glass for the panel's life, with only its content swapped: a fresh glass
    // per rebuild drew a frame or two at the stock blur before reduceGlassBlur
    // ran, so the panel's transparency flickered.
    if let glass, let scrim {
      scrim.subviews.forEach { $0.removeFromSuperview() }
      scrim.addSubview(stack)
      scrim.addSubview(ring)
      panel.setContentSize(size)
      glass.frame = frame
      glass.layoutSubtreeIfNeeded()
      reduceGlassBlur(glass)  // in case resizing rebuilt the backdrop's filter
    } else {
      let (glass, scrim) = backdrop(frame)
      scrim.addSubview(stack)
      scrim.addSubview(ring)
      self.glass = glass
      self.scrim = scrim
      panel.setContentSize(size)
      panel.contentView = glass
      // The glass layer tree only exists after layout, so soften afterwards.
      DispatchQueue.main.async { reduceGlassBlur(glass) }
    }
    if panel.isVisible { panel.setFrameTopLeftPoint(topLeft) }
    showRing()
  }

  // Liquid Glass (NSGlassEffectView, resolved at runtime — the nixpkgs SDK
  // predates it) with a translucent scrim so text stays readable, as in hidewin-bar.
  func backdrop(_ frame: NSRect) -> (NSView, Scrim) {
    let scrim = Scrim(frame: frame)
    scrim.autoresizingMask = [.width, .height]
    if let cls = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
      let glass = cls.init() as? NSView
    {
      glass.frame = frame
      glass.setValue(1, forKey: "style")
      glass.setValue(16, forKey: "cornerRadius")
      glass.setValue(scrim, forKey: "contentView")
      return (glass, scrim)
    }
    let vev = NSVisualEffectView(frame: frame)
    vev.material = .menu
    vev.state = .active
    vev.wantsLayer = true
    vev.layer?.cornerRadius = 16
    vev.layer?.masksToBounds = true
    vev.addSubview(scrim)
    return (vev, scrim)
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
  func testRow() -> NSView {
    func button(_ title: String, _ symbol: String, _ action: Selector, enabled: Bool) -> NSButton {
      let b = NSButton(
        title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
        target: self, action: action)
      b.controlSize = .small
      b.bezelStyle = .rounded
      b.imagePosition = .imageLeading
      b.isEnabled = enabled
      return focusable("test-\(title)", b)
    }
    let haveTakes = !recording && FileManager.default.fileExists(atPath: takes["raw"]!)
    // Record 8 s of raw mic, then play it as-is or through the current settings.
    let buttons = NSStackView(views: [
      button(
        recording ? "8 s…" : "Record", "record.circle", #selector(record),
        enabled: !recording),
      button(
        "Original", playing == "raw" ? "stop.fill" : "play.fill", #selector(playRaw),
        enabled: haveTakes),
      button(
        "Denoised", playing == "out" ? "stop.fill" : "play.fill", #selector(playOut),
        enabled: haveTakes),
    ])
    buttons.spacing = 4
    guard playing != nil else { return buttons }
    // Scrubbable playhead while a take plays.
    focusable("playhead", playhead)
    playhead.controlSize = .small
    playhead.target = self
    playhead.action = #selector(seek(_:))
    _ = valueLabel("", playTime)
    updatePlayhead()
    let col = NSStackView(views: [buttons, NSStackView(views: [playhead, playTime])])
    col.orientation = .vertical
    col.alignment = .leading
    return col
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
  @objc func record() {
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
    buildContent()
    source.record(seconds: 8) { [weak self] data in
      borrowed?.stop()
      borrowed = nil  // the take's callback held it
      guard let self else { return }
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
  @objc func playRaw() { toggle("raw") }
  @objc func playOut() { toggle("out") }
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
    c.call = call
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

signal(SIGPIPE, SIG_IGN)  // a dead ffmpeg must not kill us mid-write
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.dropFirst().first == "screenshot" {
  screenshots(to: CommandLine.arguments.dropFirst(2).first ?? ".")
  exit(0)
}
let controller = Controller()
signal(SIGTERM) { _ in
  controller.stop()
  exit(0)
}
app.run()
