# Builds the Firefox extension from ../../extension: bundles the TypeScript
# sources with esbuild and assembles a loadable extension (static assets +
# compiled JS), provided both as an unpacked directory and a zipped .xpi.
#
# The .xpi is unsigned, so installing it permanently requires either Firefox
# Developer Edition / ESR with `xpinstall.signatures.required = false`, or
# signing it via `web-ext sign`. For day-to-day use, loading the unpacked
# directory as a temporary add-on is the simplest path.
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
  version = "0.1.0";

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
