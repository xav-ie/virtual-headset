# Troubleshooting

## Device not showing in Zoom/Meet

1. Check the device was created:

   ```bash
   ls -l /dev/hidraw*
   # should show a device owned by you, or mode 0666
   ```

2. Check in the browser console (F12):

   ```javascript
   navigator.hid.getDevices();
   // should show "Virtual_Headset" if previously authorized
   ```

3. Check the audio device name matches:

   ```bash
   pactl list sources | grep -A5 Virtual_Headset
   ```

## Mute not working

1. Check HID events are being sent:

   ```bash
   sudo evtest
   # select the Virtual_Headset device, press 'm' — you should see KEY_MICMUTE events
   ```

2. Check the app connected to the device:
   - Look for a "Device opened by host" message in the terminal.
   - You should see "Host LEDs" messages when you mute/unmute inside Zoom.

## Mute not syncing in the Firefox web app

- Make sure the daemon is running and on the bus
  (`systemctl --user status virtual-headset`).
- Open the meeting tab's devtools console and look for `[vh]` log lines.
- Zoom/Meet may have changed their DOM — see [maintaining the site
  adapters](./browser-extension.md#maintaining-the-site-adapters).

## Permission denied errors

- Make sure you're in the `input` group: `groups | grep input`
- Check the udev rules are loaded: `udevadm info /dev/uhid`
- Restart (or re-log) after adding udev rules

See [Device permissions](./installation.md#device-permissions) for the full
setup.
