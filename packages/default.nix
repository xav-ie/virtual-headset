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
  virtual-headset-panel = pkgs.callPackage ./virtual-headset-panel {
    inherit agsPackages virtual-headset-ctl;
  };
in
# Linux: uhid daemon + PipeWire loopback. macOS: one agent (HID via
# IOHIDUserDevice, mic forwarding + optional denoising) + the
# Virtual_Headset_Microphone loopback driver.
if pkgs.stdenv.hostPlatform.isDarwin then
  {
    virtual-headset = pkgs.callPackage ./virtual-headset-macos { };
    virtual-headset-driver = pkgs.callPackage ./virtual-headset-driver { };
    virtual-headset-firefox = pkgs.callPackage ./virtual-headset-firefox { };
  }
else
  {
    inherit virtual-headset-ctl;
    virtual-headset = pkgs.callPackage ./virtual-headset { inherit craneLib virtual-headset-ctl; };
    virtual-headset-firefox = pkgs.callPackage ./virtual-headset-firefox { };
    inherit virtual-headset-panel;
    virtual-headset-panel-screenshots = pkgs.callPackage ./virtual-headset-panel-screenshots {
      inherit virtual-headset-panel;
    };
  }
