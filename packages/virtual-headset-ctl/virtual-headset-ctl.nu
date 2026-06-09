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

# Path to the configured-source file. Must match the daemon's lookup
# (src/pipewire.rs): $XDG_CONFIG_HOME/virtual-headset/source, falling back to
# ~/.config/virtual-headset/source.
def vh-config-path [] {
    let base = ($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config")
    $"($base)/virtual-headset/source"
}

# The configured source name, or "" if none is set.
def vh-configured-source [] {
    let p = (vh-config-path)
    if ($p | path exists) { (open --raw $p | str trim) } else { "" }
}

# Get the description of the source currently being forwarded: the configured
# one if set, otherwise the system default.
def "main get-source" [] {
    let configured = (vh-configured-source)
    let target = (if ($configured != "") { $configured } else { (^pactl get-default-source | str trim) })
    let match = (^pactl --format=json list sources | from json | where name == $target)
    if ($match | is-empty) { $target } else { ($match | first | get description) }
}

# List selectable input sources as JSON (for source pickers). Excludes monitor
# sources and the virtual headset's own output. Each entry is marked with
# whether it is the system default and/or the configured source.
def "main list-sources" [] {
    let default = (^pactl get-default-source | str trim)
    let configured = (vh-configured-source)
    ^pactl --format=json list sources
    | from json
    | where {|s| (not ($s.name | str ends-with ".monitor")) and ($s.name != "Virtual_Headset_Mic") }
    | each {|s| {
        name: $s.name
        description: $s.description
        default: ($s.name == $default)
        configured: (($configured != "") and ($s.name == $configured))
      } }
    | sort-by description
    | to json --raw
}

# Set the source the virtual headset forwards, then restart the service to
# apply it. Note: this restarts the daemon, so the virtual mic drops briefly —
# a between-meetings action.
def "main set-source" [name: string] {
    let exists = (^pactl --format=json list sources | from json | any {|s| $s.name == $name })
    if not $exists {
        error make {msg: $"Source not found: ($name)"}
    }
    let p = (vh-config-path)
    mkdir ($p | path dirname)
    $name | save --force --raw $p
    systemctl --user restart virtual-headset.service
}

# Revert to forwarding the system default source, then restart the service.
def "main clear-source" [] {
    let p = (vh-config-path)
    if ($p | path exists) { rm $p }
    systemctl --user restart virtual-headset.service
}

# Helper to output waybar JSON with current source (fetched dynamically)
def output-waybar-json [muted: bool, muted_icon: string, unmuted_icon: string] {
    let source_desc = (main get-source)
    if $muted {
        print $'{"text":"($muted_icon)","tooltip":"Muted: ($source_desc)","class":"muted"}'
    } else {
        print $'{"text":"($unmuted_icon)","tooltip":"Unmuted: ($source_desc)","class":"unmuted"}'
    }
}

# Monitor mute state via D-Bus and output JSON for Waybar
def "main monitor-mute" [
  muted_icon: string = " " # Icon to display when muted
  unmuted_icon: string = " " # Icon to display when unmuted
] {
    # Query initial state
    let initial = (^dbus-send --session --print-reply
        --dest=com.github.virtual_headset
        /com/github/virtual_headset
        com.github.virtual_headset.Mute.IsMuted e> /dev/null) | complete

    if $initial.exit_code == 0 {
        let is_muted = ($initial.stdout | str contains "boolean true")
        output-waybar-json $is_muted $muted_icon $unmuted_icon
    }

    # Monitor for changes
    dbus-monitor --session "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
    | lines
    | each { |line|
        if ($line =~ 'boolean\s+(true|false)') {
            let muted = ($line | parse -r 'boolean\s+(?<value>true|false)' | get value.0) == "true"
            output-waybar-json $muted $muted_icon $unmuted_icon
        }
    }
}

# Control Virtual_Headset device
def main [] {
    print "Use --help to see available commands"
}
