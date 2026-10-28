---
"virtual-headset": minor
---

Add a nix-darwin module (`darwinModules.default`): `services.virtual-headset.enable` runs the macOS app at login, puts `virtual-headset` on your `PATH`, and installs the Virtual_Headset_Microphone driver. The app now has microphone access by entitlement, since apps can't show macOS's permission prompt under the boot argument it needs.
