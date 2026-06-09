#!/usr/bin/env python3
"""Drive virtual-headset-bridge over the WebExtension native-messaging protocol,
exactly as Firefox would, and print each message it sends — one compact JSON
object per line. Argument: the path to the bridge binary (from the registered
native-messaging host manifest).
"""
import json
import struct
import subprocess
import sys
import threading
import time

bridge = sys.argv[1]
proc = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def reader() -> None:
    while True:
        hdr = proc.stdout.read(4)
        if len(hdr) < 4:
            break
        (n,) = struct.unpack("@I", hdr)
        print(proc.stdout.read(n).decode(), flush=True)


threading.Thread(target=reader, daemon=True).start()


def send(obj) -> None:
    data = json.dumps(obj).encode()
    proc.stdin.write(struct.pack("@I", len(data)) + data)
    proc.stdin.flush()


time.sleep(0.8)  # let it emit the initial state on connect
send({"type": "listSources"})
time.sleep(1.5)
proc.terminate()
