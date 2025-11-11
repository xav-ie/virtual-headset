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
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
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

          checks = {
            # Ensure all packages build successfully
            all-packages = pkgs.symlinkJoin {
              name = "virtual-headset-all";
              paths = builtins.attrValues (
                import ./packages {
                  inherit pkgs craneLib;
                  nuenv = inputs.nuenv.lib;
                }
              );
            };

            # Test that NixOS and Home Manager modules work in a VM
            modules = pkgs.testers.nixosTest {
              name = "virtual-headset-modules";
              nodes.machine =
                { config, pkgs, ... }:
                {
                  imports = [
                    inputs.self.nixosModules.default
                    inputs.home-manager.nixosModules.home-manager
                  ];

                  # NixOS module configuration
                  services.virtual-headset = {
                    enable = true;
                    user = "test";
                  };

                  users.users.test = {
                    isNormalUser = true;
                  };

                  # Home Manager module configuration
                  home-manager.users.test = {
                    imports = [ inputs.self.homeManagerModules.default ];

                    programs.waybar.enable = true;
                    programs.virtual-headset-waybar = {
                      enable = true;
                      mutedIcon = "🔇";
                      unmutedIcon = "🔊";
                    };

                    home.stateVersion = "24.05";
                  };
                };

              testScript = # python
                ''
                  machine.wait_for_unit("multi-user.target")

                  # NixOS module tests
                  # Check that packages are installed
                  machine.succeed("which virtual-headset")
                  # Check that user is in input group
                  machine.succeed("groups test | grep input")
                  # Check that udev rules file exists
                  machine.succeed("test -f /etc/udev/rules.d/99-virtual-headset.rules")
                  # Check that udev rules contain our configuration
                  machine.succeed("grep 'KERNEL==\"uhid\"' /etc/udev/rules.d/99-virtual-headset.rules")

                  # Home Manager module tests
                  # Check that waybar config contains our custom module
                  config_path = "/home/test/.config/waybar/config"
                  machine.succeed(f"test -f {config_path}")

                  # Verify the custom/virtual-headset module is configured
                  machine.succeed(f"grep 'custom/virtual-headset' {config_path}")

                  # Verify the exec command includes monitor-mute with our custom icons
                  machine.succeed(f"grep 'monitor-mute' {config_path}")
                  machine.succeed(f"grep '🔇' {config_path}")
                  machine.succeed(f"grep '🔊' {config_path}")

                  # Verify click handlers are configured
                  machine.succeed(f"grep 'toggle-mute' {config_path}")
                  machine.succeed(f"grep 'restart-service' {config_path}")

                  # Check that waybar style includes our custom CSS
                  style_path = "/home/test/.config/waybar/style.css"
                  machine.succeed(f"test -f {style_path}")
                  machine.succeed(f"grep 'custom-virtual-headset' {style_path}")
                '';
            };
          };
        };

      flake = {
        nixosModules.default =
          { pkgs, ... }:
          {
            _module.args.virtual-headset-package =
              inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.virtual-headset;
            imports = [ ./nixosModules/default.nix ];
          };

        homeManagerModules.default =
          { pkgs, ... }:
          {
            _module.args.virtual-headset-ctl =
              inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.virtual-headset-ctl;
            imports = [ ./homeManagerModules/default.nix ];
          };
      };
    };
}
