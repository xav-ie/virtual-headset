{
  dbus,
  pulseaudio,
  systemd,
  writeNuApplication,
}:
writeNuApplication {
  name = "virtual-headset-ctl";
  runtimeInputs = [
    dbus
    pulseaudio
    systemd
  ];
  text = builtins.readFile ./virtual-headset-ctl.nu;
}
