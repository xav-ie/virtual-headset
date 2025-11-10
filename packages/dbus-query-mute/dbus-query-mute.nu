#!/usr/bin/env nu
# Query current virtual headset mute state via D-Bus
# Exit code: 0 if muted, 1 if unmuted, 2 if service not available

def main [] {
  let result = dbus-send --session --print-reply
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.IsMuted
    | complete

  if $result.exit_code != 0 {
    print "unavailable"
    exit 2
  }

  if ($result.stdout | str contains "boolean true") {
    print "muted"
    exit 0
  } else if ($result.stdout | str contains "boolean false") {
    print "unmuted"
    exit 1
  } else {
    print "unavailable"
    exit 2
  }
}
