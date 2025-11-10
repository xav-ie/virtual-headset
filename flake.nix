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
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            cfg = config.services.virtual-headset;
            packages = inputs.self.packages.${pkgs.system};
          in
          {
            options.services.virtual-headset = {
              enable = lib.mkEnableOption "virtual HID telephony headset for Zoom/Meet";

              package = lib.mkOption {
                type = lib.types.package;
                default = packages.virtual-headset;
                description = "The virtual-headset package to use";
              };

              user = lib.mkOption {
                type = lib.types.str;
                description = "User to grant /dev/uhid and /dev/hidraw permissions to";
              };
            };

            config = lib.mkIf cfg.enable {
              services.udev.extraRules = ''
                # Allow access to /dev/uhid for creating virtual HID devices
                KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

                # Allow browser WebHID access to virtual headset device
                # Matches Jabra vendor (0x0b0e) product (0x245e)
                KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
              '';

              users.users.${cfg.user}.extraGroups = [ "input" ];
              environment.systemPackages = [ cfg.package ];

              systemd.user.services.virtual-headset = {
                description = "Virtual HID telephony headset for Zoom/Meet";
                after = [
                  "pipewire.service"
                  "pipewire-pulse.service"
                ];
                wants = [
                  "pipewire.service"
                  "pipewire-pulse.service"
                ];
                wantedBy = [ "graphical-session.target" ];

                serviceConfig = {
                  ExecStart = lib.getExe cfg.package;
                  Restart = "on-failure";
                  RestartSec = 5;
                };
              };
            };
          };

        homeManagerModules.default =
          {
            config,
            lib,
            pkgs,
            ...
          }:
          let
            cfg = config.programs.virtual-headset-waybar;
            packages = inputs.self.packages.${pkgs.system};
          in
          {
            options.programs.virtual-headset-waybar = {
              enable = lib.mkEnableOption "Waybar module for virtual headset mute indicator";

              mutedIcon = lib.mkOption {
                type = lib.types.str;
                default = " ";
                description = "Icon to display when muted";
              };

              unmutedIcon = lib.mkOption {
                type = lib.types.str;
                default = " ";
                description = "Icon to display when unmuted";
              };
            };

            config = lib.mkIf cfg.enable {
              programs.waybar.settings.mainBar."custom/virtual-headset" = {
                exec = "${lib.getExe packages.dbus-monitor-mute} ${lib.escapeShellArg cfg.mutedIcon} ${lib.escapeShellArg cfg.unmutedIcon}";
                return-type = "json";
                format = "{}";
                tooltip = true;
                on-click = lib.getExe packages.dbus-toggle-mute;
                on-click-right = lib.getExe packages.systemd-restart-virtual-headset;
              };

              programs.waybar.style = # css
                ''
                  #custom-virtual-headset.muted {
                    padding: 3px 8px;
                  }

                  #custom-virtual-headset.unmuted {
                    padding: 3px 8px;
                    padding-left: 12px;
                    padding-right: 4px;
                  }
                '';
            };
          };
      };
    };
}
