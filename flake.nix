{
  description = "Virtual HID telephony headset for Zoom and Google Meet";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default-linux";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    nuenv.url = "github:xav-ie/nuenv";
    nuenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          system,
          ...
        }:
        let
          craneLib = inputs.crane.mkLib pkgs;
        in
        {
          packages =
            (import ./packages {
              inherit pkgs craneLib;
              nuenv = inputs.nuenv.lib;
            })
            // {
              default = config.packages.virtual-headset;
            };

          devShells.default =
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
            pkgs.mkShell {
              packages =
                lib.optionals isLinux devPkgs
                ++ lib.optionals isDarwin (
                  with pkgs;
                  [
                    llvmPackages.libcxxStdenv
                    llvmPackages.libcxxClang
                  ]
                )
                ++ [ config.treefmt.build.wrapper ]
                ++ (with pkgs; [
                  cargo
                  rustc
                  rust-analyzer
                  clippy
                  rustfmt
                ]);

              shellHook =
                (lib.optionalString isLinux ''
                  export PKG_CONFIG_PATH="${
                    lib.concatMapStringsSep ":" (pkg: "${lib.getDev pkg}/lib/pkgconfig") devPkgs
                  }"
                  export LIBCLANG_PATH="${pkgs.libclang.lib}/lib"
                  export BINDGEN_EXTRA_CLANG_ARGS="-I${pkgs.linuxHeaders}/include -I${pkgs.glibc.dev}/include"
                '')
                + ''
                  printf "\n🎧 Virtual Headset development environment"
                  printf "\n📦 Use \e[32mcargo build\e[0m to build the project."
                  printf "\n💄 Use \e[32mtreefmt\e[0m to format the files."
                '';
            };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              rustfmt.enable = true;
              just.enable = true;
              taplo.enable = true;
              prettier.enable = true;
            };
            settings.global.excludes = [
              "*.lock"
            ];
          };
        };

      flake = {
        nixosModules.default =
          { pkgs, ... }:
          {
            imports = [
              (
                { ... }:
                {
                  _module.args.virtual-headset-package = inputs.self.packages.${pkgs.system}.virtual-headset;
                }
              )
              ./nixosModules/default.nix
            ];
          };

        homeManagerModules.default =
          { pkgs, ... }:
          {
            imports = [
              (
                { ... }:
                {
                  _module.args = {
                    inherit (inputs.self.packages.${pkgs.system})
                      dbus-monitor-mute
                      dbus-toggle-mute
                      systemd-restart-virtual-headset
                      ;
                  };
                }
              )
              ./homeManagerModules/default.nix
            ];
          };
      };
    };
}
