# Development

## Building and testing

```bash
just check   # check the flake and build all packages
just build   # build the default package
just run     # run the virtual headset
just show    # show flake outputs
```

End-to-end bridge smoke test against a running daemon:

```bash
python3 tests/bridge_smoke.py
```

The VM tests (`nix flake check`) and a manual WebHID browser tester live under
`tests/` too — see [Tests](#tests).

## Development shell

```bash
nix develop          # or simply `direnv allow` for automatic activation
```

It provides:

- the Rust toolchain (cargo, rustc, rust-analyzer, clippy, rustfmt)
- required system libraries
- formatting tools (treefmt)

## The extension

The Firefox extension is TypeScript, bundled with esbuild:

```bash
cd extension
npm install
npm run check   # typecheck + build into dist/
```

See [Browser extension](./browser-extension.md) for how the pieces fit together
and how to update the Zoom/Meet site adapters.

## Code formatting

```bash
treefmt          # or `nix fmt` if the devshell isn't active
```

## Tests

Everything runs under one command:

```bash
just check   # builds all packages + NixOS VM tests + TypeScript unit tests + treefmt
```

For a faster local loop on a single suite, you can still run them directly:

| Where                                  | What                                                          | Run directly                                    |
| -------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------- |
| `extension/test/`                      | Adapter (jsdom) + reconciler unit tests                       | `cd extension && npm test`                      |
| `packages/virtual-headset-panel/test/` | Panel logic unit tests                                        | `cd packages/virtual-headset-panel && npm test` |
| `tests/nixos/`                         | VM tests: module wiring, runtime behaviour, extension install | `nix build .#checks.<system>.runtime`           |
| `tests/bridge_smoke.py`                | Bridge ↔ daemon smoke test (live daemon)                      | `python3 tests/bridge_smoke.py`                 |
| `tests/webhid-tester/`                 | Manual WebHID page for poking the device in Chromium          | `cd tests/webhid-tester && npm run dev`         |

## Layout

| Path                                   | What                                                                 |
| -------------------------------------- | -------------------------------------------------------------------- |
| `packages/virtual-headset/`            | The Rust daemon + the `virtual-headset-bridge` native-messaging host |
| `packages/virtual-headset-ctl/`        | The `virtual-headset-ctl` CLI (Nushell)                              |
| `packages/virtual-headset-panel/`      | The AGS desktop panel                                                |
| `packages/virtual-headset-firefox/`    | Packaging for the browser extension                                  |
| `extension/`                           | The Firefox WebExtension (TypeScript)                                |
| `nixosModules/`, `homeManagerModules/` | NixOS and Home Manager modules                                       |
