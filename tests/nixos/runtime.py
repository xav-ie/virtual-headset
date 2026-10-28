import json
import shlex

RT = "/run/user/1000"
BUS = f"unix:path={RT}/bus"


def as_alice(cmd):
    inner = f"export XDG_RUNTIME_DIR={RT} DBUS_SESSION_BUS_ADDRESS={BUS}; " + cmd
    return "sudo -u alice bash -lc " + shlex.quote(inner)


machine.wait_for_unit("multi-user.target")

# Bring up alice's user session (systemd --user + PipeWire).
machine.succeed("loginctl enable-linger alice")
machine.wait_for_unit("user@1000.service")
machine.wait_until_succeeds(as_alice("pactl info"))

# Wait for the virtual source, then make it the default input.
machine.wait_until_succeeds(
    as_alice("pactl list short sources | grep -qw vh-test-source")
)
machine.succeed(as_alice("pactl set-default-source vh-test-source"))

# Start the daemon (graphical-session.target isn't reached headless).
machine.succeed(as_alice("systemctl --user start virtual-headset"))
machine.wait_until_succeeds(as_alice("systemctl --user is-active virtual-headset"))

# The virtual HID device (Jabra vendor 0B0E, product 245E) should appear
# (HID_ID is BUS:VENDOR:PRODUCT).
machine.wait_until_succeeds(
    "grep -l 00000B0E:0000245E /sys/class/hidraw/*/device/uevent"
)


def is_muted():
    out = machine.succeed(
        as_alice(
            "dbus-send --session --print-reply "
            "--dest=com.github.virtual_headset /com/github/virtual_headset "
            "com.github.virtual_headset.Mute.IsMuted"
        )
    )
    return "boolean true" in out


# Starts muted.
machine.wait_until_succeeds(
    as_alice(
        "dbus-send --session --print-reply --dest=com.github.virtual_headset "
        "/com/github/virtual_headset com.github.virtual_headset.Mute.IsMuted"
    )
)
assert is_muted(), "daemon should start muted"

# Toggle via the CLI (HID OUTPUT report path) -> unmuted.
machine.succeed(as_alice("virtual-headset-ctl toggle-mute"))
machine.wait_until_succeeds(
    as_alice(
        "dbus-send --session --print-reply --dest=com.github.virtual_headset "
        "/com/github/virtual_headset com.github.virtual_headset.Mute.IsMuted "
        "| grep -q 'boolean false'"
    )
)

# Source listing returns valid JSON including the default source.
out = machine.succeed(as_alice("virtual-headset-ctl list-sources"))
sources = json.loads(out)
assert isinstance(sources, list) and len(sources) >= 1, out
assert any(s["default"] for s in sources), "a default source should be marked"


def state():
    return json.loads(machine.succeed(as_alice("virtual-headset-ctl state")))


# The state the panel reads: no call app has the headset, unmuted by the toggle
# above, DeepFilterNet available, defaults for the rest.
s = state()
assert s["call"] == "none", s
assert s["muted"] is False, s
assert s["denoiseAvailable"] is True, s
assert s["denoise"] is False and s["keepOpen"] is False, s
assert s["strength"] == 40, s

# Strength is saved (and applied live once noise suppression is on).
machine.succeed(as_alice("virtual-headset-ctl set-strength 25"))
machine.wait_until_succeeds(as_alice("virtual-headset-ctl state | grep -q '\"strength\":25'"))
machine.succeed(as_alice("grep -qx 25 ~/.config/virtual-headset/strength"))

# Noise suppression: the service restarts with a DeepFilterNet filter-chain in
# place of pw-loopback, publishing the same virtual mic.
machine.succeed(as_alice("virtual-headset-ctl set-denoise on"))
machine.wait_until_succeeds(
    as_alice("virtual-headset-ctl state | grep -q '\"denoise\":true'"), timeout=60
)
# [n], [c]: the pattern must not match the shell that runs pgrep itself.
machine.succeed("pgrep -f virtual-headset-filter-chai[n].conf")
machine.fail("pgrep -f node.name=Virtual_Headset_Mi[c]")
machine.wait_until_succeeds(as_alice("pactl list short sources | grep -qw Virtual_Headset_Mic"))
assert state()["strength"] == 25, state()

# Strength changes reach the denoiser's DeepFilterNet control. Set while the
# chain is suspended (the daemon restarted muted), PipeWire applies it once
# audio flows; recording from the virtual mic also feeds the level meter (a
# null source is silent, so it reads the floor).
machine.succeed(as_alice("virtual-headset-ctl set-strength 20"))
machine.succeed(as_alice("virtual-headset-ctl unmute-dbus"))
machine.succeed(
    as_alice(
        "(timeout 6 pw-record --target Virtual_Headset_Mic /tmp/vh-rec.wav >/dev/null 2>&1 &) ; "
        "timeout 5 virtual-headset-ctl monitor-level > /tmp/vh-levels.txt || true"
    )
)
machine.succeed(
    as_alice("pw-dump | grep -A1 '\"dfn:Attenuation Limit (dB)\",' | grep -qE '^\\s*20\\.0+,?$'")
)
levels = machine.succeed("cat /tmp/vh-levels.txt").split()
assert levels and all(float(l) <= 0 for l in levels), levels

# The noise suppression test: a take stopped early (SIGTERM, the panel's stop)
# is still a finished WAV file; playing it denoised runs its own filter-chain,
# which stopping takes down with it.
machine.succeed(as_alice("timeout -s TERM 3 virtual-headset-ctl test-record || true"))
machine.succeed(as_alice("head -c 4 $XDG_RUNTIME_DIR/virtual-headset-take.wav | grep -q RIFF"))
machine.succeed(
    as_alice(
        "(timeout -s TERM 4 virtual-headset-ctl test-play denoised &) ; sleep 2 ; "
        "pw-cli ls Node | grep -q 'node.name = \"virtual_headset_test\"'"
    )
)
# [n], [c]: the pattern must not match the shell that runs pgrep itself.
machine.wait_until_succeeds("! pgrep -f virtual-headset-test-chai[n].conf", timeout=10)

# Keeping the mic open is saved and shows in the state.
machine.succeed(as_alice("virtual-headset-ctl set-keep-open on"))
machine.wait_until_succeeds(
    as_alice("virtual-headset-ctl state | grep -q '\"keepOpen\":true'"), timeout=60
)
