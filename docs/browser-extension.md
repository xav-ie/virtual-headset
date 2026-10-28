# Firefox

Chrome and other Chromium browsers let Zoom and Meet talk to headsets directly
(WebHID), so they work with Virtual Headset out of the box. **Firefox doesn't**,
so in Firefox the web apps never see the headset. A small extension fills the
gap, on Linux, and keeps mute in sync both ways:

- Press your mute key or click your status bar, and the Zoom or Meet tab mutes:
  the extension clicks its mic button.
- Mute in the tab, and your status bar and panel follow.

<!-- diagram:firefox-bridge -->
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="diagrams/firefox-bridge-dark.svg">
  <img src="diagrams/firefox-bridge.svg" alt="Firefox can't use headsets, so the extension presses the button for you. Virtual Headset, which knows whether you're muted, talks through a helper that lets Firefox reach it to the Firefox extension, a mic in your toolbar. The extension clicks the Zoom or Meet tab's own mic button, and reads it back so Virtual Headset knows when you click it yourself">
</picture>
<!-- /diagram:firefox-bridge -->

Zoom's desktop app doesn't need it: it talks to the headset itself.

## Using it

- **Click** the toolbar mic to toggle mute. Red means live; grey with a slash,
  muted.
- **Right-click** it for **Audio source**, to pick which mic the headset
  forwards, and **Restart service**.

## Install, with Home Manager

```nix
{
  imports = [ inputs.virtual-headset.homeManagerModules.firefox ];
  programs.virtual-headset-firefox = {
    enable = true;
    # Install the Mozilla-signed extension, kept up to date. Needs programs.firefox.
    installExtension = true;
  };
}
```

This registers the helper Firefox talks to (the native-messaging host
`virtual-headset-bridge`), and with `installExtension` has Firefox install the
signed extension from the latest release in every profile, and update it, with
no prompts.

If your `programs.firefox` package override drops the policies Home Manager sets,
add the same `ExtensionSettings` through your override's `extraPolicies`.

## Install, without Nix

```sh
# 1. Build the helper
cargo build --release --manifest-path packages/virtual-headset/Cargo.toml

# 2. Register it with Firefox
extension/static/install-native-host.sh \
  packages/virtual-headset/target/release/virtual-headset-bridge
```

3. Download `virtual_headset.xpi` from the
   [latest release](https://github.com/xav-ie/virtual-headset/releases/latest) and
   open it in Firefox. It's signed by Mozilla.

For the **Audio source** menu, `virtual-headset-ctl` must be on the helper's
`PATH` (the Nix package does this for you).

## When Zoom or Meet change

Zoom and Meet change their pages without notice, and the extension finds their
mic buttons by reading the page. If syncing stops, the fix is usually in
[`extension/src/content.ts`](../extension/src/content.ts): each site's adapter
finds the mic button and reads whether it means "muted". See
[development](development.md#the-firefox-extension) to build and test it.
