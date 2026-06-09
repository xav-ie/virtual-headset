machine.wait_for_unit("multi-user.target")

# NixOS module: package installed, user in input group, udev rules present.
machine.succeed("which virtual-headset")
machine.succeed("groups test | grep input")
machine.succeed("test -f /etc/udev/rules.d/99-virtual-headset.rules")
machine.succeed("grep 'KERNEL==\"uhid\"' /etc/udev/rules.d/99-virtual-headset.rules")

# Home Manager: the Waybar module is wired into the config.
config_path = "/home/test/.config/waybar/config"
machine.succeed(f"test -f {config_path}")
machine.succeed(f"grep 'custom/virtual-headset' {config_path}")
machine.succeed(f"grep 'monitor-mute' {config_path}")
machine.succeed(f"grep '🔇' {config_path}")
machine.succeed(f"grep '🔊' {config_path}")
machine.succeed(f"grep 'toggle-mute' {config_path}")
machine.succeed(f"grep 'restart-service' {config_path}")

style_path = "/home/test/.config/waybar/style.css"
machine.succeed(f"test -f {style_path}")
machine.succeed(f"grep 'custom-virtual-headset' {style_path}")

# Firefox bridge: the native-messaging host manifest is registered.
host_manifest = "/home/test/.mozilla/native-messaging-hosts/virtual_headset_bridge.json"
machine.succeed(f"test -f {host_manifest}")
machine.succeed(f"grep 'virtual-headset-bridge' {host_manifest}")
machine.succeed(f"grep 'virtual-headset@local' {host_manifest}")
