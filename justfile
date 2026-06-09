default:
    @just run

# flake check — runs everything: builds all packages, the NixOS VM tests
# (modules, runtime, extension install), the TypeScript unit tests (extension +
# panel), and treefmt
check:
    nix flake check

# cut a release: bump the extension version everywhere, sanity-build, then tag
# and push. The `v*` tag triggers .github/workflows/release.yml, which signs the
# extension with Mozilla (web-ext sign --channel=unlisted) and publishes the
# signed .xpi + updates.json to GitHub Releases. Usage: `just release 0.2.0`
release VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    version="{{ VERSION }}"
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "error: VERSION must be semver like 0.2.0, got '$version'" >&2
      exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
      echo "error: working tree is dirty; commit or stash first" >&2
      exit 1
    fi
    # manifest.json is the source of truth (the Nix package reads version from
    # it); keep package.json in lockstep. The `"version":` match doesn't touch
    # `"manifest_version"` (preceding char is `_`, not a quote).
    sed -i -E "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/" \
      extension/static/manifest.json extension/package.json
    # Sanity check: the package still builds and its version resolves.
    nix build .#virtual-headset-firefox
    git add extension/static/manifest.json extension/package.json
    git commit -m "release: v$version"
    # Annotated tag (a message is required when tag.forceSignAnnotated/gpgSign is
    # set); --follow-tags only pushes annotated tags anyway.
    git tag -m "v$version" "v$version"
    git push --follow-tags
    echo "Pushed v$version — watch the release workflow: gh run watch"

# show flake outputs
show:
    nix flake show

# update all inputs
update:
    nix flake update

# build the main package
build:
    nix build

# run the main package
run:
    nix run

# These are faster, but use a separate cache. Try to use `just build/run`
# instead

build-rust:
    cargo build --manifest-path packages/virtual-headset/Cargo.toml

run-rust:
    cargo run --manifest-path packages/virtual-headset/Cargo.toml
