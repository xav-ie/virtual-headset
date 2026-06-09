# VM test: the NixOS + Home Manager modules wire everything up correctly
# (udev rules, input group, Waybar config, Firefox native-host manifest).
{
  pkgs,
  inputs,
  system,
}:
pkgs.testers.nixosTest {
  name = "virtual-headset-modules";

  nodes.machine =
    { ... }:
    {
      imports = [
        inputs.self.nixosModules.default
        inputs.home-manager.nixosModules.home-manager
      ];

      services.virtual-headset = {
        enable = true;
        user = "test";
      };

      users.users.test.isNormalUser = true;

      home-manager.users.test = {
        imports = [
          inputs.self.homeManagerModules.default
          inputs.self.homeManagerModules.firefox
        ];

        programs.waybar.enable = true;
        programs.virtual-headset-waybar = {
          enable = true;
          mutedIcon = "🔇";
          unmutedIcon = "🔊";
        };

        programs.virtual-headset-firefox.enable = true;

        home.stateVersion = "26.05";
      };
    };

  testScript = builtins.readFile ./modules.py;
}
