{
  config,
  lib,
  pkgs,
  ...
}:

let
  devPkgs = with pkgs; [
    hid-tools
    pkg-config
    udev.dev
    libclang
    llvmPackages.clang
    linuxHeaders
    glibc.dev
  ];
  inherit (pkgs.stdenv) isDarwin isLinux;
in
{
  packages =
    with pkgs;
    [ ]
    ++ lib.optionals isLinux devPkgs
    ++ lib.optionals isDarwin [
      llvmPackages.libcxxStdenv
      llvmPackages.libcxxClang
    ];

  languages.rust = {
    enable = true;
    mold.enable = isLinux;
  };

  # TODO: verify on darwin machine
  stdenv = if isDarwin then pkgs.llvmPackages.stdenv else pkgs.stdenv;

  enterShell = builtins.concatStringsSep "\n" [
    (lib.optionalString isLinux # sh
      ''
        export PKG_CONFIG_PATH="${
          lib.concatMapStringsSep ":" (pkg: "${lib.getDev pkg}/lib/pkgconfig") devPkgs
        }"
        export LIBCLANG_PATH="${pkgs.libclang.lib}/lib"
        export BINDGEN_EXTRA_CLANG_ARGS="-I${pkgs.linuxHeaders}/include -I${pkgs.glibc.dev}/include"
      ''
    )
  ];

  tasks = {
    "main:build".exec = ''cargo build'';
  };
}
