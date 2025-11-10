{ dbus, writeNuApplication }:
writeNuApplication {
  name = "dbus-query-mute";
  runtimeInputs = [ dbus ];
  text = builtins.readFile ./dbus-query-mute.nu;
}
