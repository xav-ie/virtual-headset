#!/usr/bin/env nu
# Monitor virtual headset mute state via D-Bus

def main [] {
  dbus-monitor --session "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'"
  | lines
  | each { |line|
      if ($line =~ 'boolean\s+(true|false)') {
        let muted = ($line | parse -r 'boolean\s+(?<value>true|false)' | get value.0)
        if $muted == "true" {
          print "🔇 MUTED"
        } else {
          print "🔊 UNMUTED"
        }
      }
    }
}
