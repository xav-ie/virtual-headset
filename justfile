default:
    @just run

# flake check — runs everything: builds all packages, the NixOS VM tests
# (modules, runtime, extension install), the TypeScript unit tests (extension +
# panel), and treefmt
check:
    nix flake check

# note a change for the next release (run before opening a PR). Every push to
# main keeps a "chore: prepare release" PR up to date from these notes, and
# merging it publishes the release (.github/workflows/{prepare-release,release}.yml).
change:
    knope document-change

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
