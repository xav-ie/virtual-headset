# The TypeScript unit tests (browser extension + AGS panel) as flake checks,
# so `nix flake check` runs everything. npm deps are vendored reproducibly from
# each package-lock.json; bump the npmDepsHash with
# `nix run nixpkgs#prefetch-npm-deps -- <package-lock.json>` when deps change.
{ pkgs }:
let
  vitestCheck =
    {
      pname,
      src,
      npmDepsHash,
    }:
    pkgs.buildNpmPackage {
      inherit pname src npmDepsHash;
      version = "0.0.0";

      # No build step — these packages are built elsewhere (esbuild / ags); here
      # we only run their vitest suites.
      dontNpmBuild = true;
      doCheck = true;
      checkPhase = ''
        runHook preCheck
        npm test
        runHook postCheck
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        runHook postInstall
      '';
    };
in
{
  extension-unit = vitestCheck {
    pname = "virtual-headset-extension-unit";
    src = ../extension;
    npmDepsHash = "sha256-vSlVib/NnjxjvjtGvPNVbAJ+XfSLdEbZTzc2S0wtvzc=";
  };

  panel-unit = vitestCheck {
    pname = "virtual-headset-panel-unit";
    src = ../packages/virtual-headset-panel;
    npmDepsHash = "sha256-m9irY2FtSqZm+k2cUDkuPDXaLgvaAm7IcBRzBdwcxs8=";
  };
}
