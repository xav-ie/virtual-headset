// HID Report Descriptor for Telephony Device (Headset with Mute Button)
//
// Based on USB HID Usage Tables specification:
// - Usage Page 0x0B: Telephony Devices
// - Usage 0x05: Headset
// - Usage 0x20: Hook Switch
// - Usage 0x2F: Phone Mute button
//
// Report structure:
// - Input Report (ID 1): Hook switch + Mute button state (device → host)
// - Output Report (ID 2): Mute LED state (host → device)

// Descriptor optimized for Zoom compatibility
// Zoom requires Telephony collection with both INPUT and OUTPUT reports
pub const TELEPHONY_DESCRIPTOR: [u8; 133] = [
    // Telephony Collection (Zoom only looks at this - usagePage 0x0B)
    0x05, 0x0B, // Usage Page (Telephony Devices)
    0x09, 0x05, // Usage (Headset)
    0xA1, 0x01, // Collection (Application)
    // INPUT Report (device → host)
    0x85, 0x01, //   Report ID (1)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    // Hook Switch (Zoom expects usageId 720928 = 0x0B0020)
    0x09, 0x20, //   Usage (Hook Switch)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x02, //   Input (Data,Var,Abs) - Absolute to maintain off-hook state
    // Phone Mute (Zoom expects usageId 720943 = 0x0B002F)
    0x09, 0x2F, //   Usage (Phone Mute)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x06, //   Input (Data,Var,Rel) - Relative for toggle
    // Padding
    0x75, 0x06, //   Report Size (6)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x03, //   Input (Const,Var,Abs)
    // OUTPUT Report (host → device LEDs) - REQUIRED for Zoom!
    0x85, 0x02, //   Report ID (2)
    0x05, 0x08, //   Usage Page (LED)
    // Mute LED (Zoom expects usageId 524297 = 0x080009)
    0x09, 0x09, //   Usage (LED 0x09)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    // Off-Hook LED (Zoom expects usageId 524311 = 0x080017)
    0x09, 0x17, //   Usage (LED 0x17)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    // Ring LED (Zoom expects usageId 524312 = 0x080018)
    0x09, 0x18, //   Usage (LED 0x18)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x02, //   Output (Data,Var,Abs)
    // Padding
    0x75, 0x05, //   Report Size (5)
    0x95, 0x01, //   Report Count (1)
    0x91, 0x03, //   Output (Const,Var,Abs)
    0xC0, // End Collection
    // System Microphone Mute Collection (for Google Meet compatibility)
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x80, // Usage (System Control)
    0xA1, 0x01, // Collection (Application)
    0x85, 0x03, //   Report ID (3)
    0x09, 0xA9, //   Usage (System Microphone Mute)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x95, 0x01, //   Report Count (1)
    0x75, 0x01, //   Report Size (1)
    0x81, 0x06, //   Input (Data,Var,Rel) - Relative OOC
    0x75, 0x07, //   Report Size (7)
    0x81, 0x03, //   Input (Const,Var,Abs) - Padding
    // LED Output (host -> device feedback)
    0x05, 0x08, //   Usage Page (LED)
    0x09, 0x57, //   Usage (System Microphone Mute)
    0x75, 0x01, //   Report Size (1)
    0x91, 0x06, //   Output (Data,Var,Rel)
    0x75, 0x07, //   Report Size (7)
    0x91, 0x03, //   Output (Const,Var,Abs) - Padding
    0xC0, // End Collection
    // Consumer Control Collection
    0x05, 0x0C, // Usage Page (Consumer)
    0x09, 0x01, // Usage (Consumer Control)
    0xA1, 0x01, // Collection (Application)
    0x85, 0x04, //   Report ID (4)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    // Mute button
    0x09, 0xE9, //   Usage (Volume Increment)
    0x75, 0x01, //   Report Size (1 bit)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x02, //   Input (Data,Var,Abs)
    // Padding
    0x75, 0x07, //   Report Size (7 bits)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x03, //   Input (Const,Var,Abs)
    0xC0, // End Collection
];
