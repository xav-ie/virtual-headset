# Home Manager Module for the Virtual Headset Firefox bridge.
#
# This registers the `virtual_headset_bridge` native-messaging host with
# Firefox so the browser extension can talk to the running virtual-headset
# daemon over D-Bus. It keeps the headset/keyboard mute and the Zoom/Meet web
# UI in sync — see ../extension for the extension itself.
#
# ## Usage
#
# ```nix
# {
#   imports = [ virtual-headset.homeManagerModules.firefox ];
#   programs.virtual-headset-firefox.enable = true;
# }
# ```
#
# This installs the native-messaging host manifest at
# `~/.mozilla/native-messaging-hosts/virtual_headset_bridge.json`.
#
# The extension itself is unsigned. Load it as a temporary add-on via
# `about:debugging` -> This Firefox -> Load Temporary Add-on, pointing at the
# `manifest.json` inside:
#
#   <virtual-headset-firefox>/share/virtual-headset-firefox/extension/
#
# The exact store path is printed by:
#
#   nix build .#virtual-headset-firefox && ls ./result/share/virtual-headset-firefox/extension
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.programs.virtual-headset-firefox;
  system = pkgs.stdenv.hostPlatform.system;
  daemon = self.packages.${system}.virtual-headset;
  ext = self.packages.${system}.virtual-headset-firefox;
in
{
  options.programs.virtual-headset-firefox = {
    enable = lib.mkEnableOption "Firefox native-messaging bridge for the virtual headset";

    bridge = lib.mkOption {
      type = lib.types.package;
      default = daemon;
      defaultText = lib.literalExpression "virtual-headset.packages.\${system}.virtual-headset";
      description = ''
        Package providing the `virtual-headset-bridge` native-messaging host
        binary at `<pkg>/bin/virtual-headset-bridge`.
      '';
    };

    extensionId = lib.mkOption {
      type = lib.types.str;
      default = ext.extensionId or "virtual-headset@local";
      description = ''
        The extension's Gecko ID, allow-listed in the native-host manifest.
        Must match `browser_specific_settings.gecko.id` in the extension's
        manifest.json.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Register the native-messaging host so Firefox will launch the bridge when
    # the extension calls connectNative("virtual_headset_bridge").
    home.file.".mozilla/native-messaging-hosts/virtual_headset_bridge.json".text = builtins.toJSON {
      name = "virtual_headset_bridge";
      description = "Virtual Headset D-Bus bridge for the Firefox extension";
      path = "${cfg.bridge}/bin/virtual-headset-bridge";
      type = "stdio";
      allowed_extensions = [ cfg.extensionId ];
    };

    # Make the packaged extension (.xpi + unpacked dir) available in the
    # environment so it's easy to locate for loading into Firefox.
    home.packages = [ ext ];
  };
}
