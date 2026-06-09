default:
    @just run

# flake check — runs everything: builds all packages, the NixOS VM tests
# (modules, runtime, extension install), the TypeScript unit tests (extension +
# panel), and treefmt
check:
    nix flake check

# add a changeset describing your change (run before opening a PR). On merge to
# main the Version PR (.github/workflows/version.yml) consumes these into a
# version bump + CHANGELOG.
changeset:
    npm run changeset

# local alternative to the Version PR: consume pending changesets, bump + sync
# the version, commit, push, then tag. The `v*` tag triggers release.yml, which
# signs the extension with Mozilla (web-ext sign --channel=unlisted) and
# publishes the signed .xpi + updates.json to GitHub Releases.
release:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain)" ]; then
      echo "error: working tree is dirty; commit or stash first" >&2
      exit 1
    fi
    # changeset version (bump + CHANGELOG) -> sync manifest.json -> refresh lock.
    npm run version
    git add package.json package-lock.json CHANGELOG.md \
      extension/static/manifest.json .changeset
    git commit -m "chore: version packages"
    git push
    # tag-release.mjs creates v<version> and pushes it (idempotent).
    npm run tag

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
