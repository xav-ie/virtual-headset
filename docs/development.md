# Development

```sh
nix develop          # Rust, Node and the formatters (or `direnv allow`)
just check           # nix flake check: builds, VM tests, unit tests, formatting, docs
just build           # the default package
just run             # run the Linux daemon in a terminal
nix fmt              # format everything
```

- [Layout](#layout)
- [Tests](#tests)
- [The Firefox extension](#the-firefox-extension)
- [The macOS app](#the-macos-app)
- [Docs, diagrams and screenshots](#docs-diagrams-and-screenshots)
- [Releases](#releases)

## Layout

| Path                                                     |                                                                   |
| -------------------------------------------------------- | ----------------------------------------------------------------- |
| `packages/virtual-headset/`                              | the Linux daemon, and `virtual-headset-bridge` for Firefox (Rust) |
| `packages/virtual-headset-ctl/`                          | the `virtual-headset-ctl` CLI (Nushell)                           |
| `packages/virtual-headset-panel/`                        | the Linux desktop panel (AGS)                                     |
| `packages/virtual-headset-panel-screenshots/`            | the Linux panel's docs screenshots (headless sway)                |
| `packages/virtual-headset-firefox/`                      | packaging for the Firefox extension                               |
| `packages/virtual-headset-macos/`                        | the macOS app (Swift)                                             |
| `packages/virtual-headset-driver/`                       | the macOS Virtual_Headset_Microphone driver (BlackHole, renamed)  |
| `extension/`                                             | the Firefox extension (TypeScript)                                |
| `nixosModules/`, `darwinModules/`, `homeManagerModules/` | the Nix modules                                                   |
| `scripts/`                                               | the docs' diagrams and screenshots                                |

## Tests

`just check` runs everything for your platform. To run one suite:

| Where                                  | What                                                        | Run                                             |
| -------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------- |
| `extension/test/`                      | site adapters (jsdom) and the reconciler                    | `cd extension && npm test`                      |
| `packages/virtual-headset-panel/test/` | the panel's logic                                           | `cd packages/virtual-headset-panel && npm test` |
| `tests/nixos/`                         | VM tests: module wiring, runtime behaviour, Firefox install | `nix build .#checks.x86_64-linux.runtime`       |
| `tests/bridge_smoke.py`                | the Firefox bridge against a running daemon                 | `python3 tests/bridge_smoke.py`                 |
| `tests/webhid-tester/`                 | a WebHID page for poking the headset in Chromium            | `cd tests/webhid-tester && npm run dev`         |

The VM tests and the TypeScript tests run on Linux only.

## The Firefox extension

TypeScript, bundled with esbuild. `src/background.ts` is the reconciler: it keeps
one agreed state and ignores changes that echo its own action, so the tab and the
daemon converge without loops. `src/content.ts` holds the Zoom and Meet adapters.

```sh
cd extension && npm install && npm run check   # type-check and build into dist/
```

Load `extension/dist/manifest.json` from `about:debugging` to try a build
(temporary; it's gone after a restart). `virtual-headset-bridge`
([`src/bin/virtual-headset-bridge.rs`](../packages/virtual-headset/src/bin/virtual-headset-bridge.rs))
speaks the native-messaging protocol on stdio and relays to D-Bus.

## The macOS app

One Swift file, built with Nix: `nix build .#virtual-headset`. The build re-signs
the app with Apple's `codesign`, so Nix's sandbox must be `relaxed` or off, and
running it needs the [boot argument](macos.md#why-the-boot-argument).

## Docs, diagrams and screenshots

The diagrams are generated, never drawn by hand:

```sh
node scripts/diagrams.mjs       # docs/diagrams/*.svg, and the diagram blocks in the docs
node scripts/screenshots.mjs    # assets/panel/*.png and assets/screenshot.png (on a Mac)
nix run .#virtual-headset-panel-screenshots -- assets/linux-panel   # the Linux panel (on Linux)
```

- **Colors** come from [`assets/palette.json`](../assets/palette.json), a light and
  a dark theme, shared by the diagrams and the screenshots.
- **Diagrams** are built in [`scripts/diagrams.mjs`](../scripts/diagrams.mjs) from a
  few primitives (boxes, labeled links, a grid, steps, timeline lanes), themed by
  CSS classes so each is written once and rendered in both themes. A doc embeds
  one with an empty marked block, which the script fills with the `<picture>` and
  its alt text:

  ```html
  <!-- diagram:how-it-works -->
  <!-- /diagram:how-it-works -->
  ```

  `nix flake check` fails if the committed diagrams or blocks differ from what the
  script writes.

- **Screenshots** are the real macOS panel, drawn by `virtual-headset screenshot
  <dir>` with sample values, and a mock desktop around it rendered by headless
  Chrome. Each panel state flashes in the corner of your screen while it's
  captured.
- **Linux panel screenshots** are the real AGS panel, fed sample state by a stub
  `virtual-headset-ctl`, in a headless sway with a throwaway runtime dir, home
  and D-Bus session, then trimmed and optimized with oxipng
  ([`packages/virtual-headset-panel-screenshots`](../packages/virtual-headset-panel-screenshots/default.nix)).
  States the panel can't be put in from outside (Advanced open, keyboard focus)
  come from its `VIRTUAL_HEADSET_PANEL_SHOT` variable. To run it from a Mac,
  build it with a Linux builder and run it on that machine.

## Releases

Releases are cut by [knope](https://knope.tech) and signed in CI.

1. **Per change:** `just change` (`knope document-change`) asks for the kind of
   change and a summary, and writes `.changeset/<name>.md`; commit it with the
   change. That summary becomes the change's entry in `CHANGELOG.md`.
2. **Every push to main:**
   [`prepare-release.yml`](../.github/workflows/prepare-release.yml) keeps one
   "chore: prepare release" pull request open. It bumps the version in
   `package.json` (and the extension's `manifest.json`, which follows it), adds
   the notes to `CHANGELOG.md`, and removes the change files. Each run rebuilds
   it from main, so it's never stale. Run the workflow by hand to choose the
   version yourself; before 1.0, knope bumps a feature as a patch.
3. **Merging it:** [`release.yml`](../.github/workflows/release.yml) builds the
   Firefox extension and signs it on Mozilla's unlisted channel, writes
   `updates.json`, then tags `v<version>` and publishes the GitHub release with
   the changelog, `virtual_headset.xpi` and `updates.json`. Installed copies
   update from that `updates.json`.

`nix flake check` and the Lint workflow (actionlint, shellcheck, zizmor) gate
every pull request; Security runs CodeQL and dependency review while the
repository is public.

<details>
<summary><b>One-time setup</b></summary>

```sh
# Mozilla add-ons API key (https://addons.mozilla.org/developers/addon/api/key/), to sign the .xpi
gh secret set AMO_JWT_ISSUER --repo xav-ie/virtual-headset
gh secret set AMO_JWT_SECRET --repo xav-ie/virtual-headset
```

In the repository's **Settings → Actions → General**, turn on **Allow GitHub
Actions to create and approve pull requests**, so prepare-release can open the
release pull request.

</details>
