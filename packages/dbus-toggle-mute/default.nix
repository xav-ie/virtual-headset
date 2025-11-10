{ dbus, writeNuApplication }:
writeNuApplication {
  name = "dbus-toggle-mute";
  runtimeInputs = [ dbus ];
  text = builtins.readFile ./dbus-toggle-mute.nu;
}
