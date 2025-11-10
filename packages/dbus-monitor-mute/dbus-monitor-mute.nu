#!/usr/bin/env nu
# Monitor virtual headset mute state via D-Bus
# Outputs JSON format for Waybar integration

def main [
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
    if $is_muted {
      print $'{"text":"($muted_icon)","tooltip":"Muted","class":"muted"}'
    } else {
      print $'{"text":"($unmuted_icon)","tooltip":"Unmuted","class":"unmuted"}'
    }
  }

  # Monitor for changes
  dbus-monitor --session "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
  | lines
  | each { |line|
      if ($line =~ 'boolean\s+(true|false)') {
        let muted = ($line | parse -r 'boolean\s+(?<value>true|false)' | get value.0)
        if $muted == "true" {
          print $'{"text":"($muted_icon)","tooltip":"Muted","class":"muted"}'
        } else {
          print $'{"text":"($unmuted_icon)","tooltip":"Unmuted","class":"unmuted"}'
        }
      }
    }
}
