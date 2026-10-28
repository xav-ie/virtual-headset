# The docs' Linux panel screenshots: the real AGS panel, fed sample state by a
# stub `virtual-headset-ctl`, rendered in a headless sway (dark Adwaita, scale 2)
# and captured with grim, then trimmed to the panel and losslessly optimized.
# Everything runs in a throwaway XDG_RUNTIME_DIR, HOME and D-Bus session, so no
# desktop or daemon is touched.
#
#   virtual-headset-panel-screenshots <out-dir>   →  <out-dir>/<state>.png
{
  lib,
  writeShellApplication,
  writeShellScript,
  writeShellScriptBin,
  writeText,
  virtual-headset-panel,
  coreutils,
  dbus,
  grim,
  imagemagick,
  oxipng,
  sway,
  util-linux,
}:
let
  # Answers the panel from files each shot points it at: $VH_SHOT_STATE (one
  # `monitor-state` line), $VH_SHOT_LEVEL (a dB value, streamed at the daemon's
  # ~10 Hz while the panel lives; empty = mic closed) and the sample sources.
  # Everything else succeeds silently.
  stubCtl = writeShellScriptBin "virtual-headset-ctl" ''
    case "$1" in
      monitor-state) cat "$VH_SHOT_STATE" ;;
      monitor-level)
        [ -n "$VH_SHOT_LEVEL" ] || exit 0
        while kill -0 "$PPID" 2>/dev/null; do echo "$VH_SHOT_LEVEL"; sleep 0.1; done ;;
      list-sources) cat ${sources} ;;
      *) exit 0 ;;
    esac
  '';
  panel = virtual-headset-panel.override { virtual-headset-ctl = stubCtl; };

  sources = writeText "sources.json" (
    builtins.toJSON [
      {
        name = "bluez_input.liberty";
        description = "soundcore Liberty 5 Pro";
        default = true;
        configured = false;
      }
      {
        name = "alsa_input.usb-seiren";
        description = "Razer Seiren Mini";
        default = false;
        configured = false;
      }
    ]
  );
  state =
    name: overrides:
    writeText "${name}.json" (
      builtins.toJSON (
        {
          call = "unmuted";
          denoise = true;
          denoiseAvailable = true;
          keepOpen = false;
          muted = false;
          source = "soundcore Liberty 5 Pro";
          strength = 40;
        }
        // overrides
      )
    );

  # The states the docs show, mirroring the macOS panel's. `level` empty = mic
  # closed; `mode` is the panel's VIRTUAL_HEADSET_PANEL_SHOT (see Panel.tsx).
  shots = [
    {
      name = "live";
      state = state "live" { };
      level = "-24";
      mode = "";
    }
    {
      name = "muted";
      state = state "muted" { muted = true; };
      level = "";
      mode = "";
    }
    {
      name = "no-call";
      state = state "no-call" {
        call = "none";
        denoise = false;
        muted = true;
      };
      level = "";
      mode = "";
    }
    {
      name = "advanced";
      state = state "advanced" {
        call = "none";
        muted = true;
      };
      level = "";
      mode = "advanced";
    }
    {
      name = "keyboard";
      state = state "keyboard" { };
      level = "-24";
      mode = "keyboard";
    }
  ];

  swayConfig = writeText "sway-screenshots.conf" ''
    output HEADLESS-1 resolution 1000x1400 scale 2 bg #3b4252 solid_color
    default_border none
    seat seat0 hide_cursor 1
  '';

  # Inside the D-Bus session: start sway, then open, key and capture each state.
  session = writeShellScript "virtual-headset-panel-screenshots-session" ''
    set -eu
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
      sway --unsupported-gpu -c ${swayConfig} 2>"$TMP_DIR/sway.log" &
    sway=$!
    # sway must not outlive the session, or it holds the caller's output open.
    trap 'kill "$sway" 2>/dev/null || true' EXIT
    for _ in $(seq 50); do
      [ -S "$XDG_RUNTIME_DIR/wayland-1" ] && break
      sleep 0.1
    done
    # No accessibility bus to start in this session. (Portals stay: without the
    # settings portal GTK ignores the panel's dark-theme preference.)
    export WAYLAND_DISPLAY=wayland-1 GTK_A11Y=none
    ${lib.concatMapStrings (shot: ''
      # Its own process group, so the whole panel (gjs and its ctl children)
      # goes with it; otherwise the next launch would just message this instance.
      VH_SHOT_STATE=${shot.state} VH_SHOT_LEVEL=${lib.escapeShellArg shot.level} \
        VIRTUAL_HEADSET_PANEL_SHOT=${shot.mode} \
        setsid virtual-headset-panel 2>>"$TMP_DIR/panel.log" &
      pid=$!
      sleep 2
      grim "$TMP_DIR/${shot.name}.png"
      kill -KILL -- -"$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      sleep 0.5
      magick "$TMP_DIR/${shot.name}.png" -fuzz 2% -trim +repage "$OUT_DIR/${shot.name}.png"
    '') shots}
  '';
in
writeShellApplication {
  name = "virtual-headset-panel-screenshots";
  runtimeInputs = [
    coreutils
    dbus
    grim
    imagemagick
    oxipng
    panel
    sway
    util-linux
  ];
  text = ''
    OUT_DIR=$(realpath "''${1:?usage: virtual-headset-panel-screenshots <out-dir>}")
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    export OUT_DIR TMP_DIR HOME=$TMP_DIR/home XDG_RUNTIME_DIR=$TMP_DIR/run
    mkdir -p "$OUT_DIR" "$HOME" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    dbus-run-session -- ${session}
    oxipng --opt max --strip safe --quiet "$OUT_DIR"/*.png
    ls "$OUT_DIR"
  '';
  meta.platforms = lib.platforms.linux;
}
