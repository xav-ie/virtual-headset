# nix-darwin module wiring: a minimal darwin system with the agent and the
# Firefox native host enabled has to evaluate and build (the launchd agent, the
# driver install in activation, the native-messaging manifest).
{ inputs, system }:
(inputs.nix-darwin.lib.darwinSystem {
  modules = [
    inputs.self.darwinModules.default
    {
      nixpkgs.hostPlatform = system;
      system = {
        primaryUser = "ci";
        stateVersion = 6;
      };
      services.virtual-headset = {
        enable = true;
        firefox = true;
      };
    }
  ];
}).system
