import Foundation
import IOKit.hid

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
