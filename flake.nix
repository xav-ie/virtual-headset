{
  description = "Virtual HID telephony headset for Zoom and Google Meet";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    systems.url = "github:nix-systems/default-linux";
    devenv.url = "github:cachix/devenv";
    devenv-root.flake = false;
    devenv-root.url = "file+file:///dev/null";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    crane.url = "github:ipetkov/crane";
    nuenv.url = "github:xav-ie/nuenv";
    nuenv.inputs.nixpkgs.follows = "nixpkgs";
  };

  nixConfig = {
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://devenv.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.devenv.flakeModule
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

          devenv.shells.default =
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
              containers = lib.mkForce { };

              packages =
                lib.optionals isLinux devPkgs
                ++ lib.optionals isDarwin (
                  with pkgs;
                  [
                    llvmPackages.libcxxStdenv
                    llvmPackages.libcxxClang
                  ]
                )
                ++ [ config.treefmt.build.wrapper ];

              languages.rust = {
                enable = true;
                mold.enable = isLinux;
              };

              stdenv = if isDarwin then pkgs.llvmPackages.stdenv else pkgs.stdenv;

              enterShell =
                (lib.optionalString isLinux ''
                  export PKG_CONFIG_PATH="${
                    lib.concatMapStringsSep ":" (pkg: "${lib.getDev pkg}/lib/pkgconfig") devPkgs
                  }"
                  export LIBCLANG_PATH="${pkgs.libclang.lib}/lib"
                  export BINDGEN_EXTRA_CLANG_ARGS="-I${pkgs.linuxHeaders}/include -I${pkgs.glibc.dev}/include"
                '')
                + ''
                  printf "\n🎧 Virtual Headset development environment"
                  printf "\n📦 Use \e[32;just build\e[0m to build the project."
                  printf "\n💄 Use \e[32;40mtreefmt\e[0m to format the files."
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
              ".devenv/*"
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
          in
          {
            options.services.virtual-headset = {
              enable = lib.mkEnableOption "virtual HID telephony headset for Zoom/Meet";

              package = lib.mkOption {
                type = lib.types.package;
                default = inputs.self.packages.${pkgs.system}.virtual-headset;
                description = "The virtual-headset package to use";
              };

              user = lib.mkOption {
                type = lib.types.str;
                description = "User to grant /dev/uhid and /dev/hidraw permissions to";
              };

              waybar = {
                enable = lib.mkEnableOption "Waybar module for virtual headset mute indicator";
              };
            };

            config = lib.mkMerge [
              # Base configuration - udev rules and permissions
              (lib.mkIf cfg.enable {
                services.udev.extraRules = ''
                  # Allow access to /dev/uhid for creating virtual HID devices
                  KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"

                  # Allow browser WebHID access to virtual headset device
                  # Matches Jabra vendor (0x0b0e) product (0x245e)
                  KERNEL=="hidraw*", KERNELS=="0003:0B0E:245E.*", MODE="0666", TAG+="uaccess"
                '';

                users.users.${cfg.user}.extraGroups = [ "input" ];
                environment.systemPackages = [ cfg.package ];
              })

              # Waybar integration (requires home-manager)
              (lib.mkIf (cfg.enable && cfg.waybar.enable) {
                home-manager.users.${cfg.user} = {
                  programs.waybar.settings.mainBar."custom/virtual-headset" = {
                    exec = "${pkgs.writeShellScript "waybar-virtual-headset" ''
                      # Initial state query
                      if ${pkgs.dbus}/bin/dbus-send --session --print-reply \
                          --dest=com.github.virtual_headset \
                          /com/github/virtual_headset \
                          com.github.virtual_headset.Mute.IsMuted 2>/dev/null | grep -q "boolean true"; then
                        echo '{"text":"🔇","tooltip":"Muted","class":"muted"}'
                      else
                        echo '{"text":"🔊","tooltip":"Unmuted","class":"unmuted"}'
                      fi

                      # Listen for real-time D-Bus signal updates
                      ${pkgs.dbus}/bin/dbus-monitor --session \
                        "type='signal',interface='com.github.virtual_headset.Mute',member='MuteChanged'" 2>/dev/null | \
                      while read -r line; do
                        if [[ "$line" =~ boolean[[:space:]]+(true|false) ]]; then
                          if [ "''${BASH_REMATCH[1]}" = "true" ]; then
                            echo '{"text":"🔇","tooltip":"Muted","class":"muted"}'
                          else
                            echo '{"text":"🔊","tooltip":"Unmuted","class":"unmuted"}'
                          fi
                        fi
                      done
                    ''}";
                    return-type = "json";
                    format = "{}";
                    tooltip = true;
                  };

                  programs.waybar.style = ''
                    #custom-virtual-headset.muted {
                      color: #f38ba8; /* Catppuccin red/pink */
                    }

                    #custom-virtual-headset.unmuted {
                      color: #a6e3a1; /* Catppuccin green */
                    }
                  '';
                };
              })
            ];
          };
      };
    };
}
