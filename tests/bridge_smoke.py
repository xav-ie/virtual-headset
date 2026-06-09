#!/usr/bin/env python3
"""End-to-end smoke test for virtual-headset-bridge against the live daemon.

Speaks the WebExtension native-messaging protocol (native-endian u32 length
prefix + UTF-8 JSON) to the bridge on its stdio, and cross-checks state via
dbus-send. Requires the virtual-headset daemon to be running on the session bus.
"""
import json
import struct
import subprocess
import sys
import threading
import time
import queue

BRIDGE = sys.argv[1] if len(sys.argv) > 1 else (
    "packages/virtual-headset/target/debug/virtual-headset-bridge"
)


def dbus_is_muted():
    out = subprocess.check_output([
        "dbus-send", "--session", "--print-reply",
        "--dest=com.github.virtual_headset",
        "/com/github/virtual_headset",
        "com.github.virtual_headset.Mute.IsMuted",
    ], text=True)
    return "boolean true" in out


def find_hidraw():
    """Locate the virtual headset's hidraw node (Jabra 0B0E:245E)."""
    import glob
    import os
    for d in glob.glob("/sys/class/hidraw/hidraw*"):
        uevent = os.path.join(d, "device", "uevent")
        try:
            with open(uevent) as f:
                txt = f.read()
        except OSError:
            continue
        if "0B0E" in txt.upper() and "245E" in txt.upper():
            node = "/dev/" + os.path.basename(d)
            if os.access(node, os.W_OK):
                return node
    return None


def hidraw_toggle(node):
    """Toggle mute via HID OUTPUT report ID 3 — the path ctl/keybinds use."""
    with open(node, "wb") as f:
        f.write(bytes([0x03, 0x03]))


def main():
    proc = subprocess.Popen(
        [BRIDGE], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    msgs = queue.Queue()

    def reader():
        while True:
            hdr = proc.stdout.read(4)
            if len(hdr) < 4:
                break
            (n,) = struct.unpack("@I", hdr)
            body = proc.stdout.read(n)
            msgs.put(json.loads(body))

    threading.Thread(target=reader, daemon=True).start()

    def send(obj):
        data = json.dumps(obj).encode()
        proc.stdin.write(struct.pack("@I", len(data)) + data)
        proc.stdin.flush()

    def expect_state(timeout=4):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = msgs.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if m.get("type") == "state":
                return m["muted"]
            print(f"   (ignored host msg: {m})")
        raise AssertionError("timed out waiting for a state message")

    failures = 0

    def check(name, cond):
        nonlocal failures
        print(f"[{'PASS' if cond else 'FAIL'}] {name}")
        if not cond:
            failures += 1

    def drain():
        while not msgs.empty():
            msgs.get_nowait()

    def expect_no_state(timeout=0.6):
        """Assert no state message arrives within the window (idempotency)."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                m = msgs.get(timeout=deadline - time.time())
            except queue.Empty:
                return True
            if m.get("type") == "state":
                return False
        return True

    try:
        # 1. Initial state pushed on connect should match the daemon.
        initial = expect_state()
        check("initial state matches daemon", initial == dbus_is_muted())

        # 2. query -> state
        send({"type": "query"})
        q = expect_state()
        check("query returns daemon state", q == dbus_is_muted())

        # Drive deterministic transitions starting from the known state. The
        # daemon only emits MuteChanged on a *real* change, so we only expect a
        # state message when the value actually flips.
        cur = dbus_is_muted()

        # 3. setMute(opposite) -> flips + relayed
        send({"type": "setMute", "muted": not cur})
        s = expect_state()
        time.sleep(0.2)
        check(f"setMute({not cur}) -> host reports {not cur}", s == (not cur))
        check(f"setMute({not cur}) -> daemon changed", dbus_is_muted() == (not cur))
        cur = not cur

        # 4. setMute(same) -> idempotent no-op, no signal
        drain()
        send({"type": "setMute", "muted": cur})
        check("setMute(same) is a no-op (no signal)", expect_no_state())
        check("setMute(same) leaves daemon unchanged", dbus_is_muted() == cur)

        # 5. setMute(opposite) again -> flips back
        send({"type": "setMute", "muted": not cur})
        s = expect_state()
        time.sleep(0.2)
        check("setMute flips back", s == (not cur) and dbus_is_muted() == (not cur))
        cur = not cur

        # 6. toggle
        drain()
        send({"type": "toggle"})
        s = expect_state()
        time.sleep(0.2)
        check("toggle flips state", s == (not cur) and dbus_is_muted() == (not cur))
        cur = not cur

        # 7. External change via the hidraw report-ID-3 path (the one that
        # virtual-headset-ctl and the keybinds use) is relayed to the host.
        node = find_hidraw()
        if node:
            drain()
            hidraw_toggle(node)
            s = expect_state()
            check("hidraw (ctl/keybind) change relayed to host", s == (not cur))
            cur = not cur
        else:
            print("[SKIP] hidraw node not found/writable — skipping ctl-path test")

        # 8. ping/pong liveness
        send({"type": "ping"})
        deadline = time.time() + 3
        got_pong = False
        while time.time() < deadline:
            try:
                m = msgs.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if m.get("type") == "pong":
                got_pong = True
                break
        check("ping -> pong", got_pong)

    finally:
        proc.stdin.close()
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()

    print()
    print("ALL PASSED" if failures == 0 else f"{failures} FAILURE(S)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
