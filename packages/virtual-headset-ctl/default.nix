{
  dbus,
  systemd,
  writeNuApplication,
}:
writeNuApplication {
  name = "virtual-headset-ctl";
  runtimeInputs = [
    dbus
    systemd
  ];
  text = builtins.readFile ./virtual-headset-ctl.nu;
}
