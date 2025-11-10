{ dbus, writeNuApplication }:
writeNuApplication {
  name = "dbus-monitor-mute";
  runtimeInputs = [ dbus ];
  text = builtins.readFile ./dbus-monitor-mute.nu;
}
