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
  virtual-headset-ctl = pkgs.callPackage ./virtual-headset-ctl { inherit writeNuApplication; };
}
