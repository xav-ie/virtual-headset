# NixOS Module for Virtual Headset
#
# This module provides a systemd user service and udev rules for the virtual-headset
# application, which creates a virtual USB HID telephony headset for Zoom and Google Meet.
#
# ## Features
#
# - Creates a virtual USB HID device that appears as a physical headset to conferencing apps
# - Forwards audio from your real microphone through PipeWire
# - Sends mute button events via USB HID telephony protocol
# - Receives LED feedback from apps (mute/hook/ring indicators)
#
# ## Usage
#
# Add to your `flake.nix`:
#
# ```nix
# {
#   inputs.virtual-headset.url = "github:yourusername/virtual-headset";
#
#   outputs = { self, nixpkgs, virtual-headset, ... }: {
#     nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
#       modules = [
#         virtual-headset.nixosModules.default
#         {
#           services.virtual-headset = {
#             enable = true;
#             user = "yourusername";
#           };
#         }
#       ];
#     };
#   };
# }
# ```
#
# This automatically:
#
# - Sets up udev rules for `/dev/uhid` and `/dev/hidraw*`
# - Creates a systemd user service that starts on login
# - Adds the package to your environment
# - Adds your user to the `input` group
#
# ## Service Control
#
# The service starts automatically when you log in. Control it with:
#
# ```bash
# systemctl --user status virtual-headset
# systemctl --user restart virtual-headset
# ```

{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.virtual-headset;

  udevRules = pkgs.writeTextFile {
    name = "99-virtual-headset.rules";
    text = # sh
      ''
        # Allow access to /dev/uhid for creating virtual HID devices
        KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

        # Allow browser WebHID access to virtual headset device
        # Matches Jabra vendor (0x0b0e) product (0x245e)
        KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
      '';
    destination = "/lib/udev/rules.d/99-virtual-headset.rules";
  };
in
{
  options.services.virtual-headset = {
    enable = lib.mkEnableOption "virtual HID telephony headset for Zoom/Meet";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.virtual-headset.override {
        pipewire = cfg.pipewirePackage;
        pulseaudio = cfg.pulseaudioPackage;
      };
      description = ''
        The virtual-headset package to use.

        This package provides the main virtual-headset application that creates
        the virtual HID device and manages audio routing through PipeWire.
      '';
    };

    pipewirePackage = lib.mkOption {
      type = lib.types.package;
      default = config.services.pipewire.package or pkgs.pipewire;
      description = ''
        The pipewire package to use for audio routing.

        Defaults to the system's configured pipewire package to reduce closure size.
      '';
    };

    pulseaudioPackage = lib.mkOption {
      type = lib.types.package;
      default = config.services.pulseaudio.package or pkgs.pulseaudio;
      description = ''
        The pulseaudio package to use for pactl commands.

        Defaults to the system's configured pulseaudio package to reduce closure size.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        User to grant `/dev/uhid` and `/dev/hidraw` permissions to.

        This user will be added to the `input` group and will be able to
        create virtual HID devices and access the created hidraw devices.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Udev rules for device access
    services.udev.packages = [ udevRules ];

    # Add user to input group for uhid access
    users.users.${cfg.user}.extraGroups = [ "input" ];

    # Make the package available in the environment
    environment.systemPackages = [ cfg.package ];

    # Systemd user service
    systemd.user.services.virtual-headset = {
      description = "Virtual HID telephony headset for Zoom/Meet";

      # Ensure PipeWire is running before starting
      after = [
        "pipewire.service"
        "pipewire-pulse.service"
      ];
      wants = [
        "pipewire.service"
        "pipewire-pulse.service"
      ];

      # Start automatically on login
      wantedBy = [ "graphical-session.target" ];

      # Restart the service when the package changes (e.g., after package update)
      restartTriggers = [ cfg.package ];

      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
