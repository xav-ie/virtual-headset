{ systemd, writeNuApplication }:
writeNuApplication {
  name = "systemd-restart-virtual-headset";
  runtimeInputs = [ systemd ];
  text = builtins.readFile ./systemd-restart-virtual-headset.nu;
}
