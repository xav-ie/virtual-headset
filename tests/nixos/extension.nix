# VM test: the browser-extension *install* end to end. Verifies the Home
# Manager firefox module registers the native-messaging host, that its
# allowed_extensions matches the packaged extension's id, and that driving the
# registered bridge with real native-messaging frames (as Firefox would) relays
# the daemon's mute state and source list.
#
# It does not drive a headless Firefox/Zoom UI — that needs a display, unsigned
# add-on loading, host spoofing and a Zoom DOM mock; the content-script logic is
# covered by the jsdom adapter unit tests instead.
{
  pkgs,
  inputs,
  system,
}:
let
  ext = inputs.self.packages.${system}.virtual-headset-firefox;
  extManifest = "${ext}/share/virtual-headset-firefox/extension/manifest.json";
in
pkgs.testers.nixosTest {
  name = "virtual-headset-extension";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        (import ./machine.nix { inherit inputs system; })
        inputs.home-manager.nixosModules.home-manager
      ];

      # The native-messaging probe, driven by the test as the `alice` user.
      environment.systemPackages = [ pkgs.python3 ];
      environment.etc."vh-bridge-probe.py".source = ./bridge_probe.py;

      home-manager.users.alice = {
        imports = [ inputs.self.homeManagerModules.firefox ];
        programs.virtual-headset-firefox.enable = true;
        home.stateVersion = "26.05";
      };
    };

  testScript = "ext_manifest = ${builtins.toJSON extManifest}\n" + builtins.readFile ./extension.py;
}
