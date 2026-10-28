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

## Releases

Releases are driven by [changesets](https://github.com/changesets/changesets) and
signed in CI.

- **Per change:** `just changeset`, and commit the file it writes.
- **To ship:** [`version.yml`](../.github/workflows/version.yml) keeps a "chore:
  version packages" pull request open that bumps the version, syncs it into the
  extension's `manifest.json` and writes `CHANGELOG.md`. Merging it tags
  `v<version>`, and [`release.yml`](../.github/workflows/release.yml) signs the
  Firefox extension on Mozilla's unlisted channel and publishes
  `virtual_headset.xpi` and `updates.json` to a GitHub release, which installed
  copies update from. `just release` does the bump and tag locally instead.

<details>
<summary><b>One-time setup: repository secrets</b></summary>

```sh
# Mozilla add-ons API key (https://addons.mozilla.org/developers/addon/api/key/), to sign the .xpi
gh secret set AMO_JWT_ISSUER --repo xav-ie/virtual-headset
gh secret set AMO_JWT_SECRET --repo xav-ie/virtual-headset

# A GitHub App with Contents and Pull requests read/write, installed on the repo:
# version.yml acts as it so its tag push can start release.yml.
gh secret set APP_ID --repo xav-ie/virtual-headset --body "<app id>"
gh secret set APP_PRIVATE_KEY --repo xav-ie/virtual-headset < /path/to/key.pem
```

</details>
