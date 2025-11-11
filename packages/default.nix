{
  pkgs,
  nuenv,
  craneLib,
}:
let
  writeNuApplication = nuenv.mkNushellScriptApplication pkgs.nushell pkgs.writeTextFile pkgs.lib;
in
{
  virtual-headset = pkgs.callPackage ./virtual-headset { inherit craneLib; };
  dbus-monitor-mute = pkgs.callPackage ./dbus-monitor-mute { inherit writeNuApplication; };
  dbus-query-mute = pkgs.callPackage ./dbus-query-mute { inherit writeNuApplication; };
  dbus-toggle-mute = pkgs.callPackage ./dbus-toggle-mute { inherit writeNuApplication; };
  dbus-mute = pkgs.callPackage ./dbus-mute { inherit writeNuApplication; };
  dbus-unmute = pkgs.callPackage ./dbus-unmute { inherit writeNuApplication; };
  systemd-restart-virtual-headset = pkgs.callPackage ./systemd-restart-virtual-headset {
    inherit writeNuApplication;
  };
}
