# Builds the Firefox extension from ../../extension: bundles the TypeScript
# sources with esbuild and assembles a loadable extension (static assets +
# compiled JS), provided both as an unpacked directory and a zipped .xpi.
#
# The .xpi produced here is UNSIGNED — useful for local dev / temporary add-on
# loads (`about:debugging`) while hacking on the site adapters. The permanent,
# installable build is signed by Mozilla in CI: the release workflow
# (../../.github/workflows/release.yml) runs `web-ext sign --channel=unlisted`
# on a `v*` tag, then publishes the signed .xpi + an `updates.json` to GitHub
# Releases. Firefox installs that signed build (see the Home-Manager module
# ../../homeManagerModules/firefox.nix) and auto-updates via the manifest's
# `update_url`.
#
# `version` is read from ../../extension/static/manifest.json so the manifest is
# the single source of truth (bumped by `just release`).
#
# The esbuild flags here mirror ../../extension/build.mjs; keep them in sync.
{
  lib,
  stdenvNoCC,
  esbuild,
  zip,
}:
let
  extId = "virtual-headset@local";
in
stdenvNoCC.mkDerivation {
  pname = "virtual-headset-firefox";
  version = (lib.importJSON ../../extension/static/manifest.json).version;

  src = ../../extension;

  nativeBuildInputs = [
    esbuild
    zip
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # Static assets (manifest.json at the root) + compiled JS make up the
    # loadable extension.
    cp -r static dist

    esbuild \
      src/background.ts src/content.ts \
      --bundle --format=iife --target=firefox115 --outdir=dist

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Unpacked extension for temporary loads and for the Home-Manager native-
    # host module to reference.
    mkdir -p "$out/share/virtual-headset-firefox"
    cp -r dist "$out/share/virtual-headset-firefox/extension"

    # Zipped, installable .xpi. Must be zipped from inside the extension dir so
    # manifest.json sits at the archive root.
    ( cd dist && zip -r -X "$out/share/virtual-headset-firefox/${extId}.xpi" . )

    runHook postInstall
  '';

  passthru.extensionId = extId;

  meta = with lib; {
    description = "Firefox extension bridging the virtual headset to Zoom/Meet web apps";
    license = licenses.mit;
    platforms = platforms.all;
  };
}
