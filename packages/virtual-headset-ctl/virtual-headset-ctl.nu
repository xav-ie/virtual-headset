#!/usr/bin/env nu

# Control and monitor Virtual_Headset HID device

# Find the hidraw device path for Virtual_Headset
def "main find-device" [] {
    let vendor = "0B0E"  # Jabra vendor ID (uppercase hex without 0x)
    let product = "245E" # Virtual headset product ID

    # Search through all hidraw devices
    let devices = (ls /sys/class/hidraw/ | get name)

    for device in $devices {
        let device_name = ($device | path basename)
        let uevent_path = $"/sys/class/hidraw/($device_name)/device/uevent"

        if ($uevent_path | path exists) {
            let uevent = (open $uevent_path | lines)
            let hid_id = ($uevent | find "HID_ID" | first | split row "=" | last)

            # HID_ID format is BUS:VENDOR:PRODUCT (e.g., 0003:00000B0E:0000245E)
            if ($hid_id | str contains $vendor) and ($hid_id | str contains $product) {
                return $"/dev/($device_name)"
            }
        }
    }

    error make {msg: "Virtual_Headset device not found"}
}

# Mute via HID OUTPUT report (report ID 3), more reliable than dbus
def "main mute" [] {
  let device = (main find-device)
  0x[03 01] | save --raw --force $device
}

# Unmute via HID OUTPUT report (report ID 3), more reliable than dbus
def "main unmute" [] {
  let device = (main find-device)
  0x[03 02] | save --raw --force $device
}

# Toggle mute via HID OUTPUT report (report ID 3), more reliable than dbus
def "main toggle-mute" [] {
  let device = (main find-device)
  0x[03 03] | save --raw --force $device
}

# Mute via D-Bus
def "main mute-dbus" [] {
  (^dbus-send --session
    --type=method_call
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.Mute)
}

# Unmute via D-Bus
def "main unmute-dbus" [] {
  (^dbus-send --session
    --type=method_call
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.Unmute)
}

# Toggle mute via dbus
def "main toggle-mute-dbus" [] {
  (^dbus-send --session --print-reply
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.Toggle) | ignore
}

# Restart the virtual-headset systemd user service
def "main restart-service" [] {
  systemctl --user restart virtual-headset.service
}

# Get the description of the default audio source being forwarded
def "main get-source" [] {
    let source_name = (^pactl get-default-source | str trim)
    let sources = (^pactl list sources | lines)
    mut found_source = false
    for line in $sources {
        let trimmed = ($line | str trim)
        if ($trimmed | str starts-with "Name: ") and ($trimmed | str contains $source_name) {
            $found_source = true
        } else if $found_source and ($trimmed | str starts-with "Description: ") {
            return ($trimmed | str replace "Description: " "")
        }
    }
    $source_name
}

# Monitor mute state via D-Bus and output JSON for Waybar
def "main monitor-mute" [
  muted_icon: string = " " # Icon to display when muted
  unmuted_icon: string = " " # Icon to display when unmuted
] {
    # Get the source description for the tooltip
    let source_desc = (main get-source)

    # Query initial state
    let initial = (^dbus-send --session --print-reply
        --dest=com.github.virtual_headset
        /com/github/virtual_headset
        com.github.virtual_headset.Mute.IsMuted e> /dev/null) | complete

    if $initial.exit_code == 0 {
        let is_muted = ($initial.stdout | str contains "boolean true")
        if $is_muted {
            print $'{"text":"($muted_icon)","tooltip":"Muted: ($source_desc)","class":"muted"}'
        } else {
            print $'{"text":"($unmuted_icon)","tooltip":"Unmuted: ($source_desc)","class":"unmuted"}'
        }
    }

    # Monitor for changes
    dbus-monitor --session "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
    | lines
    | each { |line|
        if ($line =~ 'boolean\s+(true|false)') {
            let muted = ($line | parse -r 'boolean\s+(?<value>true|false)' | get value.0)
            if $muted == "true" {
                print $'{"text":"($muted_icon)","tooltip":"Muted: ($source_desc)","class":"muted"}'
            } else {
                print $'{"text":"($unmuted_icon)","tooltip":"Unmuted: ($source_desc)","class":"unmuted"}'
            }
        }
    }
}

# Control Virtual_Headset device
def main [] {
    print "Use --help to see available commands"
}
