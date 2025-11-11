// HID Telephony Device Descriptor
//
// Implements a standard USB HID Telephony Headset compatible with Zoom and Google Meet.
//
// Features:
// - Hook Switch: Absolute state (off-hook = in call, on-hook = hung up)
// - Phone Mute: Relative toggle (each pulse toggles mute state)
// - LED Feedback: Host can send mute/hook/ring LED states back to device
// - Feature Control: External control commands via feature report
//
// Report Structure:
// - Report ID 1 (INPUT):   Hook switch (bit 0) + Mute button (bit 1) → host
// - Report ID 2 (OUTPUT):  Mute LED (bit 0) + OffHook LED (bit 1) + Ring LED (bit 2) → device (from host)
// - Report ID 3 (OUTPUT):  Control command (0x01=mute, 0x02=unmute, 0x03=toggle) → device (from CLI)
//
pub const TELEPHONY_DESCRIPTOR: [u8; 85] = [
    0x05, 0x0B, // Usage Page (Telephony Devices)
    0x09, 0x05, // Usage (Headset)
    0xA1, 0x01, // Collection (Application)
    // INPUT Report: Button states from device to host
    0x85, 0x01, //   Report ID (1)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x09, 0x20, //   Usage (Hook Switch)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x02, //   Input (Data,Var,Abs) - Absolute state
    0x09, 0x2F, //   Usage (Phone Mute)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x06, //   Input (Data,Var,Rel) - Relative toggle
    0x75, 0x06, //   Report Size (6 bits padding)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x03, //   Input (Const,Var,Abs)
    // OUTPUT Report: LED states from host to device
    0x85, 0x02, //   Report ID (2)
    0x05, 0x08, //   Usage Page (LED)
    0x09, 0x09, //   Usage (Mute LED)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    0x09, 0x17, //   Usage (Off-Hook LED)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    0x09, 0x18, //   Usage (Ring LED)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    0x75, 0x05, //   Report Size (5 bits padding)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x03, //   Output (Const,Var,Abs)
    // OUTPUT Report: Control commands (from CLI)
    0x85, 0x03, //   Report ID (3)
    0x05, 0x0B, //   Usage Page (Telephony Devices)
    0x09, 0x2F, //   Usage (Phone Mute)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x03, //   Logical Maximum (3)
    0x75, 0x08, //   Report Size (8 bits)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    0xC0, // End Collection
];
