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

# Push-to-talk state shared by ptt-press and ptt-release: the press time in
# nanoseconds, "latched" (a tap left the mic open) or "stopping" (the press
# that closes it).
def ptt-state-path [] {
  $env.XDG_RUNTIME_DIR? | default "/tmp" | path join "virtual-headset-ptt"
}

# Push-to-talk key down: unmute, or mute if a tap left the mic open
def "main ptt-press" [] {
  let state = (ptt-state-path)
  if ($state | path exists) and (open --raw $state | str trim) == "latched" {
    "stopping" | save --force $state
    main mute
    return
  }
  date now | into int | into string | save --force $state
  main unmute
}

# Push-to-talk key up: a tap (under 300 ms) keeps the mic open until the next
# press, a hold mutes
def "main ptt-release" [] {
  let state = (ptt-state-path)
  let last = if ($state | path exists) { open --raw $state | str trim } else { "" }
  match $last {
    "stopping" => { rm --force $state }
    "" | "latched" => {}
    _ => {
      if ((date now | into int) - ($last | into int)) < 300_000_000 {
        "latched" | save --force $state
      } else {
        rm --force $state
        main mute
      }
    }
  }
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

# Path to a settings file. Must match the daemon's lookup (src/settings.rs):
# $XDG_CONFIG_HOME/virtual-headset/<name>, falling back to
# ~/.config/virtual-headset/<name>.
def vh-config-path [name: string] {
    let base = ($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config")
    $"($base)/virtual-headset/($name)"
}

# The configured source name, or "" if none is set.
def vh-configured-source [] {
    let p = (vh-config-path source)
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
    let p = (vh-config-path source)
    mkdir ($p | path dirname)
    $name | save --force --raw $p
    systemctl --user restart virtual-headset.service
}

# Revert to forwarding the system default source, then restart the service.
def "main clear-source" [] {
    let p = (vh-config-path source)
    if ($p | path exists) { rm $p }
    systemctl --user restart virtual-headset.service
}

# Save an on/off setting the daemon reads at start, then restart it to apply.
# The virtual mic drops for about a second: a between-meetings action.
def vh-set-flag [name: string, value: string] {
    if $value not-in [on off] {
        error make {msg: $"Expected on or off, got: ($value)"}
    }
    let p = (vh-config-path $name)
    mkdir ($p | path dirname)
    $value | save --force --raw $p
    systemctl --user restart virtual-headset.service
}

# Turn noise suppression (DeepFilterNet) on or off; restarts the service
def "main set-denoise" [value: string] {
    vh-set-flag denoise $value
}

# Keep the mic open between calls (on), or only while an app records from
# Virtual_Headset_Microphone (off, the default); restarts the service
def "main set-keep-open" [value: string] {
    vh-set-flag keep-open $value
}

# Call a method on the daemon's D-Bus interface; busctl's JSON reply
def vh-call [method: string, ...args: string] {
    (^busctl --user --json=short call
        com.github.virtual_headset /com/github/virtual_headset
        com.github.virtual_headset.Mute $method ...$args)
    | from json
}

# Set noise suppression's strength, its attenuation limit in dB (0 to 40, the
# top of which is "Max"); applies live
def "main set-strength" [db: number] {
    vh-call SetStrength d ($db | into string) | ignore
}

# The daemon's state as JSON: call (none/muted/unmuted), muted, source,
# denoise, denoiseAvailable, strength and keepOpen
def "main state" [] {
    vh-call GetState | get data.0
}

# Print each argument the daemon sends with a signal, one line per emission
def vh-monitor [member: string] {
    (^busctl --user --json=short monitor
        $"--match=type='signal',interface='com.github.virtual_headset.Mute',member='($member)'")
    | lines
    | each {|line|
        let message = (try { $line | from json } catch { null })
        if ($message != null) and ($message.member? == $member) {
            print ($message.payload.data.0 | into string)
        }
    }
    | ignore
}

# Stream the state as JSON lines: the current one, then one per change
def "main monitor-state" [] {
    print (main state)
    vh-monitor StateChanged
}

# Stream the virtual mic's level in dBFS, about 10 lines a second while audio
# flows
def "main monitor-level" [] {
    vh-monitor Level
}

# Where the noise suppression test keeps its take
def vh-take-path [] {
    $env.XDG_RUNTIME_DIR? | default "/tmp" | path join "virtual-headset-take.wav"
}

# The source the daemon forwards: the configured one, else the system default
def vh-forwarded-source [] {
    let configured = (vh-configured-source)
    if ($configured != "") { $configured } else { ^pactl get-default-source | str trim }
}

# Record 8 s of your mic, raw, for test-play. Opens the mic for the take.
# SIGTERM ends it early and keeps what it has: `timeout` passes the signal on,
# and pw-record finishes the file.
def "main test-record" [] {
    exec timeout -s INT 8 pw-record --target (vh-forwarded-source) --rate 48000 --channels 1 (vh-take-path)
}

# Play the take: `original` as recorded, or `denoised` through noise
# suppression at its current strength, live, the way a call would hear it.
# SIGTERM stops it.
def "main test-play" [which: string] {
    let take = (vh-take-path)
    if not ($take | path exists) {
        error make {msg: "No take yet: run test-record first"}
    }
    match $which {
        original => { exec pw-play $take }
        denoised => { vh-play-denoised $take }
        _ => { error make {msg: $"Expected original or denoised, got: ($which)"} }
    }
}

# Play a file through a short-lived filter-chain sink running the same
# DeepFilterNet plugin as the daemon, at the current strength, out to the
# default speakers.
def vh-play-denoised [take: string] {
    let plugin = ($env.VIRTUAL_HEADSET_LADSPA? | default "")
    if ($plugin == "") or not ($plugin | path exists) {
        error make {msg: "Noise suppression isn't available in this build"}
    }
    let strength = (main state | from json | get strength)
    let conf = ($env.XDG_RUNTIME_DIR? | default "/tmp" | path join "virtual-headset-test-chain.conf")
    $"context.spa-libs = {
  audio.convert.* = audioconvert/libspa-audioconvert
  support.*       = support/libspa-support
}
context.modules = [
  { name = libpipewire-module-protocol-native }
  { name = libpipewire-module-client-node }
  { name = libpipewire-module-adapter }
  { name = libpipewire-module-filter-chain
    args = {
      node.description = \"Virtual Headset test\"
      filter.graph = {
        nodes = [
          {
            type    = ladspa
            name    = dfn
            plugin  = \"($plugin)\"
            label   = deep_filter_mono
            control = { \"Attenuation Limit \(dB\)\" = ($strength) }
          }
        ]
      }
      audio.rate     = 48000
      audio.channels = 1
      audio.position = [ MONO ]
      capture.props  = { node.name = virtual_headset_test media.class = Audio/Sink }
      playback.props = { node.name = virtual_headset_test_out node.passive = true }
    }
  }
]
" | save --force $conf
    # One shell owns the chain and the playback, so a SIGTERM (the panel's
    # stop) ends both. The filter-chain only loads plugins from LADSPA_PATH's
    # directories.
    exec sh -c '
        LADSPA_PATH="$1" pipewire -c "$2" >/dev/null 2>&1 & chain=$!
        trap "kill $chain $play 2>/dev/null" EXIT INT TERM
        for _ in $(seq 50); do
            pw-cli ls Node | grep -q "node.name = \"virtual_headset_test\"" && break
            sleep 0.1
        done
        pw-play --target virtual_headset_test "$3" & play=$!
        wait $play
    ' sh ($plugin | path dirname) $conf $take
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
