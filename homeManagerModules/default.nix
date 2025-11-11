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
# The module uses the `dbus-monitor-mute` utility to subscribe to D-Bus signals
# from the virtual-headset service. When the mute state changes, it outputs JSON
# in Waybar's custom module format with the appropriate icon and CSS class.
#
# The D-Bus interface provides:
# - Service: `com.github.virtual_headset`
# - Object Path: `/com/github/virtual_headset`
# - Interface: `com.github.virtual_headset.Mute`
# - Signal: `MuteChanged(bool muted)`
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
  dbus-monitor-mute ? null,
  dbus-toggle-mute ? null,
  systemd-restart-virtual-headset ? null,
  ...
}:
let
  cfg = config.programs.virtual-headset-waybar;

  # Packages provided by the flake when importing this module
  packages = {
    dbus-monitor-mute =
      if dbus-monitor-mute != null then
        dbus-monitor-mute
      else
        throw ''
          dbus-monitor-mute package not provided. This module should be imported
          from the virtual-headset flake which provides the packages automatically.
        '';
    dbus-toggle-mute =
      if dbus-toggle-mute != null then
        dbus-toggle-mute
      else
        throw ''
          dbus-toggle-mute package not provided. This module should be imported
          from the virtual-headset flake which provides the packages automatically.
        '';
    systemd-restart-virtual-headset =
      if systemd-restart-virtual-headset != null then
        systemd-restart-virtual-headset
      else
        throw ''
          systemd-restart-virtual-headset package not provided. This module should be imported
          from the virtual-headset flake which provides the packages automatically.
        '';
  };
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
    # Configure the Waybar custom module
    programs.waybar.settings.mainBar."custom/virtual-headset" = {
      # Use the dbus-monitor-mute utility with custom icons
      exec = "${lib.getExe packages.dbus-monitor-mute} ${lib.escapeShellArg cfg.mutedIcon} ${lib.escapeShellArg cfg.unmutedIcon}";
      return-type = "json";
      format = "{}";
      tooltip = true;
      on-click = lib.getExe packages.dbus-toggle-mute;
      on-click-right = lib.getExe packages.systemd-restart-virtual-headset;
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
