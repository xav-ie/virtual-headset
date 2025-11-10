#!/usr/bin/env nu
# Restart the virtual-headset systemd user service

def main [] {
  systemctl --user restart virtual-headset.service
}
