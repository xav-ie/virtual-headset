# AGS (Astal) panel mirroring the virtual-headset mute state and adding a source
# picker. Bundled into a standalone gjs binary. `agsPackages` is
# inputs.ags.packages.<system>, re-exporting the astal libraries (io, astal4)
# alongside the ags CLI (default).
#
# All actions go through `virtual-headset-ctl`, wrapped onto PATH below, so the
# panel shares the same control surface as the bar module and the browser bridge.
{
  stdenv,
  wrapGAppsHook3,
  gobject-introspection,
  gjs,
  agsPackages,
  virtual-headset-ctl,
}:
stdenv.mkDerivation {
  name = "virtual-headset-panel";
  src = ./.;

  nativeBuildInputs = [
    wrapGAppsHook3
    gobject-introspection
    agsPackages.default
  ];

  # On GI_TYPELIB_PATH at runtime via the gobject-introspection setup hook.
  buildInputs = [
    gjs
    agsPackages.io
    agsPackages.astal4
  ];

  # The bundled gjs binary spawns virtual-headset-ctl directly.
  preFixup = ''
    gappsWrapperArgs+=(--prefix PATH : ${virtual-headset-ctl}/bin)
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    ags bundle app.ts $out/bin/virtual-headset-panel
    install -Dm644 icon.svg $out/share/icons/hicolor/scalable/apps/virtual-headset-panel.svg
    runHook postInstall
  '';

  meta = {
    description = "AGS panel for virtual-headset mute + source selection";
    mainProgram = "virtual-headset-panel";
  };
}
