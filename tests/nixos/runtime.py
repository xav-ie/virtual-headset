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
