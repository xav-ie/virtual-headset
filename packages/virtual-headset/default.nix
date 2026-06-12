{
  lib,
  pkgs,
  craneLib,
  pulseaudio ? pkgs.pulseaudio,
  pipewire ? pkgs.pipewire,
  # For the bridge's source listing/selection (listSources/setSource). Optional
  # so the package still builds standalone; the native-host wrapping is skipped
  # when null.
  virtual-headset-ctl ? null,
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

  unwrapped = craneLib.buildPackage (
    commonArgs
    // {
      inherit cargoArtifacts;

      meta = with lib; {
        description = "Virtual HID telephony headset for Zoom and Google Meet";
        license = licenses.mit;
        platforms = platforms.linux;
      };
    }
  );
in
pkgs.symlinkJoin {
  name = "virtual-headset";
  paths = [ unwrapped ];
  buildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/virtual-headset \
      --prefix PATH : ${
        lib.makeBinPath [
          pulseaudio
          pipewire
          pkgs.procps # pkill, for kill_existing_loopbacks
        ]
      }
    ${lib.optionalString (virtual-headset-ctl != null) ''
      # The native-messaging bridge shells out to virtual-headset-ctl for
      # source listing/selection.
      wrapProgram $out/bin/virtual-headset-bridge \
        --prefix PATH : ${lib.makeBinPath [ virtual-headset-ctl ]}
    ''}
  '';
  meta = unwrapped.meta // {
    mainProgram = "virtual-headset";
  };
}
