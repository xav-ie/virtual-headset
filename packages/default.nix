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
}
