# `ext_manifest` (the path to the packaged extension's manifest.json) is
# injected by extension.nix above this script.
import json
import shlex

RT = "/run/user/1000"
BUS = f"unix:path={RT}/bus"


def as_alice(cmd):
    inner = f"export XDG_RUNTIME_DIR={RT} DBUS_SESSION_BUS_ADDRESS={BUS}; " + cmd
    return "sudo -u alice bash -lc " + shlex.quote(inner)


machine.wait_for_unit("multi-user.target")

# Bring up the user session + PipeWire and start the daemon (as in runtime).
machine.succeed("loginctl enable-linger alice")
machine.wait_for_unit("user@1000.service")
machine.wait_until_succeeds(as_alice("pactl info"))
machine.wait_until_succeeds(
    as_alice("pactl list short sources | grep -qw vh-test-source")
)
machine.succeed(as_alice("pactl set-default-source vh-test-source"))
machine.succeed(as_alice("systemctl --user start virtual-headset"))
machine.wait_until_succeeds(as_alice("systemctl --user is-active virtual-headset"))
machine.wait_until_succeeds(
    "grep -l 00000B0E:0000245E /sys/class/hidraw/*/device/uevent"
)

# The Home Manager firefox module registered the native-messaging host.
host_path = "/home/alice/.mozilla/native-messaging-hosts/virtual_headset_bridge.json"
machine.succeed(f"test -f {host_path}")
host = json.loads(machine.succeed(f"cat {host_path}"))
assert host["name"] == "virtual_headset_bridge", host

# Install invariant: the host allow-lists exactly the extension's id, otherwise
# Firefox refuses the connectNative() call.
ext = json.loads(machine.succeed(f"cat {ext_manifest}"))
ext_id = ext["browser_specific_settings"]["gecko"]["id"]
assert ext_id in host["allowed_extensions"], (ext_id, host["allowed_extensions"])

# The registered bridge binary exists and is executable (the Nix-wrapped one,
# with virtual-headset-ctl on its PATH).
bridge = host["path"]
machine.succeed(f"test -x {bridge}")

# Drive the bridge exactly as Firefox would (native-messaging frames) and check
# it relays the daemon's state and the source list end to end.
out = machine.succeed(as_alice(f"python3 /etc/vh-bridge-probe.py {bridge}"))
msgs = [json.loads(line) for line in out.splitlines() if line.strip()]

states = [m for m in msgs if m.get("type") == "state"]
assert states, msgs
assert states[0]["muted"] is True, msgs  # daemon starts muted

sources = [m for m in msgs if m.get("type") == "sources"]
assert sources, msgs
names = [s["name"] for s in sources[-1]["sources"]]
assert "vh-test-source" in names, msgs
