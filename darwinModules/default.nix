# nix-darwin module for Virtual Headset
#
# Runs the macOS agent at login and installs the Virtual_Headset_Microphone
# loopback driver it plays into. See docs/macos.md.
#
# ```nix
# darwinConfigurations.mac = nix-darwin.lib.darwinSystem {
#   modules = [
#     virtual-headset.darwinModules.default
#     { services.virtual-headset.enable = true; }
#   ];
# };
# ```
#
# Needs `amfi_get_out_of_my_way=1` in the boot args (the agent's HID device and
# microphone access come from entitlements an ad-hoc signature can't otherwise
# hold) and Nix's sandbox relaxed or off (the build re-signs the app with Apple's
# codesign).
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.virtual-headset;
  packages = self.packages.${pkgs.stdenv.hostPlatform.system};
  firefoxHost = pkgs.writeText "virtual_headset_bridge.json" (
    builtins.toJSON {
      name = "virtual_headset_bridge";
      description = "Virtual Headset bridge for the Firefox extension";
      path = "${cfg.package}/bin/virtual-headset-bridge";
      type = "stdio";
      allowed_extensions = [ packages.virtual-headset-firefox.extensionId ];
    }
  );
in
{
  options.services.virtual-headset = {
    enable = lib.mkEnableOption "the Virtual Headset agent: a mute-syncing headset for Zoom and Meet";

    package = lib.mkOption {
      type = lib.types.package;
      default = packages.virtual-headset;
      defaultText = lib.literalExpression "virtual-headset.packages.\${system}.virtual-headset";
      description = "The agent: `virtual-headset.app` plus the `virtual-headset` CLI.";
    };

    driverPackage = lib.mkOption {
      type = lib.types.package;
      default = packages.virtual-headset-driver;
      defaultText = lib.literalExpression "virtual-headset.packages.\${system}.virtual-headset-driver";
      description = "The Virtual_Headset_Microphone loopback driver (a renamed BlackHole).";
    };

    firefox = lib.mkEnableOption ''
      the Firefox extension's native-messaging host, for every user. Firefox has
      no WebHID, so this is how Zoom and Meet tabs in Firefox stay in sync; install
      the signed extension itself from the latest release'';

    logDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp";
      description = "Where the agent's `virtual-headset.{out,err}.log` go.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The CLI: `virtual-headset panel | mute | unmute | toggle-mute`.
    environment.systemPackages = [ cfg.package ];

    launchd.user.agents.virtual-headset.serviceConfig = {
      ProgramArguments = [
        "${cfg.package}/Applications/virtual-headset.app/Contents/MacOS/virtual-headset"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      # Changes with the package, so launchd restarts the agent on updates.
      EnvironmentVariables.VIRTUAL_HEADSET_PKG = "${cfg.package}";
      StandardOutPath = "${cfg.logDir}/virtual-headset.out.log";
      StandardErrorPath = "${cfg.logDir}/virtual-headset.err.log";
    };

    # coreaudiod only scans HAL plug-ins when it starts, so it's restarted when
    # the driver changes (all audio drops for a moment), and only then. Firefox
    # reads native-messaging hosts for all users from /Library.
    system.activationScripts.postActivation.text = ''
      ${lib.optionalString cfg.firefox ''
        hosts="/Library/Application Support/Mozilla/NativeMessagingHosts"
        mkdir -p "$hosts"
        cp ${firefoxHost} "$hosts/virtual_headset_bridge.json"
        chmod 644 "$hosts/virtual_headset_bridge.json"
      ''}

      src=${cfg.driverPackage}/Library/Audio/Plug-Ins/HAL/VirtualHeadset.driver
      dst=/Library/Audio/Plug-Ins/HAL/VirtualHeadset.driver
      if ! diff -rq "$src" "$dst" >/dev/null 2>&1; then
        echo "virtual-headset: installing VirtualHeadset.driver, restarting coreaudiod" >&2
        rm -rf "$dst"
        cp -R "$src" "$dst"
        chmod -R u+w,go-w "$dst"
        killall coreaudiod || true
      fi
    '';
  };
}
