{
  lib,
  pkgs,
  craneLib,
}:
let
  src = craneLib.cleanCargoSource ./.;

  commonArgs = {
    inherit src;
    strictDeps = true;

    nativeBuildInputs = with pkgs; [
      pkg-config
      llvmPackages.clang
    ];

    buildInputs = with pkgs; [
      udev
      linuxHeaders
      glibc.dev
    ];

    LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
    BINDGEN_EXTRA_CLANG_ARGS = "-I${pkgs.linuxHeaders}/include -I${pkgs.glibc.dev}/include";
  };

  # Build dependencies separately for better caching
  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    meta = with lib; {
      description = "Virtual HID telephony headset for Zoom and Google Meet";
      license = licenses.mit;
      platforms = platforms.linux;
    };
  }
)
