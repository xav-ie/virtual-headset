{ dbus, writeNuApplication }:
writeNuApplication {
  name = "dbus-unmute";
  runtimeInputs = [ dbus ];
  text = builtins.readFile ./dbus-unmute.nu;
}
