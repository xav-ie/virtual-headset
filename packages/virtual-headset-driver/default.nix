# BlackHole loopback driver renamed to Virtual_Headset_Microphone: mic-denoise
# plays into its output side and the call app records from its input side. Zoom
# pairs a WebHID headset with the selected mic when the mic's label includes the
# HID product name ("Virtual_Headset"), so the name is load-bearing.
# kCanBeDefaultDevice=false keeps it from ever becoming the system output.
# The overrides are prepended to BlackHole.c: xcbuild drops command-line
# GCC_PREPROCESSOR_DEFINITIONS, so nixpkgs' own flags never reach the compiler.
{ blackhole }:
let
  name = "Virtual_Headset_Microphone";
  bundleId = "com.github.virtual-headset.driver";
in
blackhole.overrideAttrs (old: {
  pname = "virtual-headset-driver";
  inherit bundleId;
  xcbuildFlags = [
    "-project"
    "BlackHole.xcodeproj"
    "-configuration"
    "Release"
    "PRODUCT_BUNDLE_IDENTIFIER=${bundleId}"
  ];
  postPatch = (old.postPatch or "") + ''
    cat - BlackHole/BlackHole.c > BlackHole.c.new <<'EOF'
    #define kNumber_Of_Channels 2
    #define kHas_Driver_Name_Format false
    #define kDriver_Name "${name}"
    #define kDevice_Name "${name}"
    #define kManufacturer_Name "virtual-headset"
    #define kPlugIn_BundleID "${bundleId}"
    #define kCanBeDefaultDevice false
    #define kCanBeDefaultSystemDevice false
    EOF
    mv BlackHole.c.new BlackHole/BlackHole.c
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out/Library/Audio/Plug-Ins/HAL
    mv Products/Release/BlackHole.driver $out/Library/Audio/Plug-Ins/HAL/VirtualHeadset.driver
    runHook postInstall
  '';
  meta = old.meta // {
    description = "Virtual_Headset_Microphone loopback device (BlackHole) for virtual-headset on macOS";
  };
})
