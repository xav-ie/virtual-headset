#!/usr/bin/env nu
# Toggle virtual headset mute state via D-Bus

def main [] {
  (^dbus-send --session
    --type=method_call
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.Toggle)
}
