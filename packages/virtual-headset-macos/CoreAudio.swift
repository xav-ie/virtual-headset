import CoreAudio
import Foundation

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
