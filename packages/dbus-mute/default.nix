{ dbus, writeNuApplication }:
writeNuApplication {
  name = "dbus-mute";
  runtimeInputs = [ dbus ];
  text = builtins.readFile ./dbus-mute.nu;
}
