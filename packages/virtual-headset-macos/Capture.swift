import AVFoundation

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

  // Ends the take in progress early, handing over what it has so far.
  func finishTake() {
    queue.async {
      guard let t = self.take, let done = self.takeDone else { return }
      self.take = nil
      DispatchQueue.main.async { done(t) }
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
