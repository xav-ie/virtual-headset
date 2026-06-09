{
  pkgs,
  nuenv,
  craneLib,
  # inputs.ags.packages.<system>; needed by the AGS panel (linux-only).
  agsPackages,
}:
let
  writeNuApplication = nuenv.mkNushellScriptApplication pkgs.nushell pkgs.writeTextFile pkgs.lib;
  virtual-headset-ctl = pkgs.callPackage ./virtual-headset-ctl { inherit writeNuApplication; };
in
{
  inherit virtual-headset-ctl;
  virtual-headset = pkgs.callPackage ./virtual-headset { inherit craneLib virtual-headset-ctl; };
  virtual-headset-firefox = pkgs.callPackage ./virtual-headset-firefox { };
  virtual-headset-panel = pkgs.callPackage ./virtual-headset-panel {
    inherit agsPackages virtual-headset-ctl;
  };
}
