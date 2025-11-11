#!/usr/bin/env nu
# Set virtual headset to muted state via D-Bus

def main [] {
  (^dbus-send --session
    --type=method_call
    --dest=com.github.virtual_headset
    /com/github/virtual_headset
    com.github.virtual_headset.Mute.Mute)
}
