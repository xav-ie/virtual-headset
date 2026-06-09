# Browser extension (Firefox)

Chromium-based browsers expose the virtual HID device to web pages through
WebHID, so Zoom/Meet web apps work with it directly. **Firefox does not
implement WebHID**, so the web apps never see the virtual headset there.

This repo ships a small Firefox extension plus a native-messaging host
(`virtual-headset-bridge`) that talks to the daemon over D-Bus, keeping mute (and
the audio source) in sync in the browser — **both ways**:

- Press your keyboard/status-bar mute and the Zoom/Meet tab mutes (the extension
  clicks its mic button).
- Mute from Zoom/Meet's own UI and your status bar / headset indicator follow.

```mermaid
graph LR
    Key["mute key / virtual-headset-ctl"] --> Daemon[virtual-headset daemon]
    Daemon -->|"MuteChanged signal"| DBus[D-Bus]
    DBus <--> Bridge["virtual-headset-bridge<br/>(native-messaging host)"]
    Bridge <-->|stdio JSON| Ext[Firefox extension]
    Ext <-->|"read state / click mute"| Web["Zoom / Meet web tab"]
```

> [!NOTE]
> For the **native** Zoom desktop client, the existing HID path already works and
> the extension isn't needed.

## Using it

- **Left-click** the toolbar mic icon → toggle mute. The icon shows the state
  (red = live, gray + slash = muted).
- **Right-click** the icon → an **Audio source** menu (pick which mic the headset
  forwards) and **Restart service**.

## Install (Nix / Home Manager)

```nix
{
  imports = [ virtual-headset.homeManagerModules.firefox ];
  programs.virtual-headset-firefox.enable = true;
}
```

This registers the native-messaging host at
`~/.mozilla/native-messaging-hosts/virtual_headset_bridge.json` and puts the
packaged extension on your profile. Find the unpacked extension:

```bash
nix build .#virtual-headset-firefox
ls ./result/share/virtual-headset-firefox/extension   # load manifest.json from here
```

Then load it in Firefox via **about:debugging → This Firefox → Load Temporary
Add-on** and pick that `manifest.json`.

> The build also produces an unsigned `virtual-headset@local.xpi`. A temporary
> add-on resets on restart. Installing it permanently on release Firefox requires
> signing it (`web-ext sign --channel=unlisted`), or using Firefox Developer
> Edition/ESR with `xpinstall.signatures.required = false`.

## Install (without Nix)

```bash
# 1. Build the bridge binary
cargo build --release --manifest-path packages/virtual-headset/Cargo.toml

# 2. Register the native-messaging host
extension/static/install-native-host.sh \
  packages/virtual-headset/target/release/virtual-headset-bridge

# 3. Build the extension, then load extension/dist/manifest.json via about:debugging
cd extension && npm install && npm run build
```

For source selection to work, `virtual-headset-bridge` needs `virtual-headset-ctl`
on its `PATH` (the Nix package wires this up automatically).

## How it's built

- **`extension/`** — a TypeScript WebExtension bundled with esbuild.
  `src/background.ts` is the reconciler (keeps a single agreed state and ignores
  changes that echo its own action, so the two sides converge without feedback
  loops); `src/content.ts` holds the per-site DOM adapters for Zoom + Meet.
- **`virtual-headset-bridge`** — a second binary in the `virtual-headset` crate
  ([`src/bin/virtual-headset-bridge.rs`](../packages/virtual-headset/src/bin/virtual-headset-bridge.rs))
  that speaks the WebExtension native-messaging protocol on stdio, relays mute
  state to/from D-Bus, and shells out to `virtual-headset-ctl` for source
  listing/selection.

## Maintaining the site adapters

Zoom and Meet change their DOM without notice. If sync stops working, update the
adapters in [`extension/src/content.ts`](../extension/src/content.ts) — each one
just needs to find the mic button and read whether it currently means "muted".
Type-check and rebuild with `npm run check` inside `extension/`.
