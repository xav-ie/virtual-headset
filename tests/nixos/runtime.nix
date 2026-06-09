# VM test: boot the service with headless audio and exercise the runtime
# behaviour — device creation, starts muted, toggle, and source listing.
{
  pkgs,
  inputs,
  system,
}:
pkgs.testers.nixosTest {
  name = "virtual-headset-runtime";
  nodes.machine = import ./machine.nix { inherit inputs system; };
  testScript = builtins.readFile ./runtime.py;
}
