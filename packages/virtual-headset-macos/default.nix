{
  deepfilternet,
  fetchFromGitHub,
  lib,
  ffmpeg-full,
  stdenv,
  swift,
}:
# virtual-headset — the macOS agent (see main.swift). Ships as a .app
# with a stable bundle id so a Microphone TCC grant can pin this bundle's cdhash;
# ffmpeg runs as its child, so the grant covers it. Needs virtual-headset-driver
# installed for its Virtual_Headset_Microphone output.
let
  models = fetchFromGitHub {
    owner = "GregorR";
    repo = "rnnoise-models";
    rev = "3eee541a283fd3b8f81b85b1748e3b9ccbefa04d";
    hash = "sha256-+0QtVNTb9VGvO7D0IRSqBWBF2BfT/pO/ZLt5gbCsEqU=";
  };
in
stdenv.mkDerivation {
  pname = "virtual-headset";
  version = "0.1.0";
  src = ./.;
  nativeBuildInputs = [ swift ];
  buildPhase = ''
    runHook preBuild
    # ffmpeg-full: the default ffmpeg is built --disable-ladspa (needed for DeepFilterNet).
    cat > Paths.swift <<'EOF'
    let DFN_LADSPA = "${deepfilternet}/lib/ladspa/libdeep_filter_ladspa.dylib"
    let FFMPEG = "${ffmpeg-full.bin}/bin/ffmpeg"
    EOF
    swiftc -O -import-objc-header ladspa.h main.swift Paths.swift -o virtual-headset
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    app=$out/Applications/virtual-headset.app
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/models"
    cp virtual-headset "$app/Contents/MacOS/virtual-headset"
    cp ${models}/*/*.rnnn "$app/Contents/Resources/models/"
    cat > "$app/Contents/Info.plist" <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>virtual-headset</string>
      <key>CFBundleIdentifier</key><string>com.github.virtual-headset</string>
      <key>CFBundleName</key><string>Virtual Headset</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>0.1.0</string>
      <key>LSUIElement</key><true/>
      <key>NSMicrophoneUsageDescription</key><string>Forwards your mic into Virtual_Headset_Microphone.</string>
    </dict></plist>
    EOF
    mkdir -p $out/bin
    ln -s "$app/Contents/MacOS/virtual-headset" $out/bin/virtual-headset
    runHook postInstall
  '';

  # Seal the bundle with its final identity after stdenv's darwin fixup (which
  # would otherwise re-sign the Mach-O back to "virtual-headset"). Ad-hoc signed,
  # both entitlements only hold with amfi_get_out_of_my_way=1:
  #   hid.virtual.device  create the Virtual_Headset HID device
  #   private.tcc.allow   microphone access; with AMFI relaxed the app can't
  #                       raise the usual permission prompt
  # Needs Apple's /usr/bin/codesign, hence __noChroot (build with sandbox =
  # relaxed or false).
  __noChroot = true;
  postFixup = ''
    cat > entitlements.plist <<'EOF'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>com.apple.developer.hid.virtual.device</key><true/>
      <key>com.apple.private.tcc.allow</key>
      <array><string>kTCCServiceMicrophone</string></array>
    </dict></plist>
    EOF
    /usr/bin/codesign --force --sign - --identifier com.github.virtual-headset \
      --entitlements entitlements.plist "$out/Applications/virtual-headset.app"
  '';

  meta = {
    license = lib.licenses.mit;
    mainProgram = "virtual-headset";
    platforms = lib.platforms.darwin;
  };
}
