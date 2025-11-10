override_args := '--override-input devenv-root $"file+file://(pwd)/.devenv/root"'

default:
    @just run

# flake check and build
check:
    #!/usr/bin/env nu
    nix flake check {{ override_args }}
    just build

# show flake outputs
show:
    #!/usr/bin/env nu
    nix flake show {{ override_args }}

# update all inputs
update:
    nix flake update

# build the main package
build:
    #!/usr/bin/env nu
    nix build {{ override_args }}

# run the main package
run:
    #!/usr/bin/env nu
    nix run {{ override_args }}

# These are faster, but use a separate cache. Try to use `just build/run`
# instead

build-rust:
    cargo build --manifest-path packages/virtual-headset/Cargo.toml

run-rust:
    cargo run --manifest-path packages/virtual-headset/Cargo.toml
