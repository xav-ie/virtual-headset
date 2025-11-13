# Home Manager Module for Virtual Headset Waybar Integration
#
# This module provides a Waybar integration for the virtual-headset application,
# allowing you to see and control the mute state directly from your status bar.
#
# ## Features
#
# - Displays real-time mute status with configurable icons
# - Shows initial state on launch
# - Updates instantly when mute state changes via D-Bus
# - Click to toggle mute
# - Right-click to restart the service
# - Integrates seamlessly with your existing Waybar configuration
#
# ## Usage
#
# Add to your Home Manager configuration:
#
# ```nix
# {
#   imports = [ virtual-headset.homeManagerModules.default ];
#
#   programs.virtual-headset-waybar = {
#     enable = true;
#     mutedIcon = " ";      # Nerd Font icon for muted
#     unmutedIcon = " ";    # Nerd Font icon for unmuted
#   };
# }
# ```
#
# Then add the module to your Waybar configuration:
#
# ```nix
# programs.waybar.settings.mainBar.modules-right = [
#   # ... your other modules
#   "custom/virtual-headset"
# ];
# ```
#
# ## How It Works
#
# The module uses `virtual-headset-ctl monitor-mute` to subscribe to D-Bus signals from the
# virtual-headset service. When the mute state changes (controlled by Zoom/Meet
# via HID LED events), the Rust application emits a D-Bus signal, and Waybar
# updates instantly with the appropriate icon and CSS class.
#
# Control is done via `virtual-headset-ctl` which sends HID OUTPUT reports (report ID 3)
# directly to the device, providing a reliable way to toggle mute.
#
# ## Customization
#
# You can customize the appearance in your Waybar style.css:
#
# ```css
# #custom-virtual-headset.muted {
#   color: #ff0000;
# }
#
# #custom-virtual-headset.unmuted {
#   color: #00ff00;
# }
# ```

{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.programs.virtual-headset-waybar;
  ctl = self.packages.${pkgs.stdenv.hostPlatform.system}.virtual-headset-ctl;
in
{
  options.programs.virtual-headset-waybar = {
    enable = lib.mkEnableOption "Waybar module for virtual headset mute indicator";

    mutedIcon = lib.mkOption {
      type = lib.types.str;
      default = " ";
      description = ''
        Icon to display when the microphone is muted.

        Defaults to a Nerd Font microphone slash icon.
        You can use any Unicode character or Nerd Font icon.
      '';
      example = " ";
    };

    unmutedIcon = lib.mkOption {
      type = lib.types.str;
      default = " ";
      description = ''
        Icon to display when the microphone is unmuted.

        Defaults to a Nerd Font microphone icon.
        You can use any Unicode character or Nerd Font icon.
      '';
      example = " ";
    };
  };

  config = lib.mkIf cfg.enable {
    # Install virtual-headset-ctl for user access
    home.packages = [ ctl ];

    # Configure the Waybar custom module
    programs.waybar.settings.mainBar."custom/virtual-headset" = {
      # Monitor mute state via D-Bus for event-driven updates
      exec = "${lib.getExe ctl} monitor-mute ${lib.escapeShellArg cfg.mutedIcon} ${lib.escapeShellArg cfg.unmutedIcon}";
      return-type = "json";
      format = "{}";
      tooltip = true;
      # Control mute via HID device directly
      on-click = "${lib.getExe ctl} toggle-mute";
      on-click-right = "${lib.getExe ctl} restart-service";
    };

    # Add default styling for the module
    programs.waybar.style = # css
      ''
        #custom-virtual-headset.muted {
          padding: 3px 8px;
        }

        #custom-virtual-headset.unmuted {
          padding: 3px 8px;
          padding-left: 12px;
          padding-right: 4px;
        }
      '';
  };
}
