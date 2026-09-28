#!/usr/bin/env python3
"""A stand-in for headless Chromium that speaks just enough DevTools protocol
over --remote-debugging-pipe (fd 3 in, fd 4 out) for one capture to complete,
and appends every message it receives as a JSON line to the file named by
FAKE_BROWSER_LOG. Lets a test see exactly what the driver asked the browser.
"""
import json
import os

# A 1x1 transparent PNG, base64.
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

log = open(os.environ["FAKE_BROWSER_LOG"], "a")
inp = os.fdopen(3, "rb", 0)
out = os.fdopen(4, "wb", 0)


def send(message):
    out.write(json.dumps(message).encode() + b"\0")


buffer = b""
while True:
    chunk = inp.read(65536)
    if not chunk:
        break
    buffer += chunk
    while b"\0" in buffer:
        frame, buffer = buffer.split(b"\0", 1)
        message = json.loads(frame)
        log.write(json.dumps(message) + "\n")
        log.flush()

        method = message.get("method")
        session = message.get("sessionId")
        result = {
            "Target.createTarget": {"targetId": "T1"},
            "Target.attachToTarget": {"sessionId": "S1"},
            "Page.captureScreenshot": {"data": PNG},
        }.get(method, {})

        reply = {"id": message["id"], "result": result}
        if session:
            reply["sessionId"] = session
        send(reply)

        if method == "Browser.close":
            raise SystemExit(0)
        if method == "Page.navigate":
            # Without a load event the driver waits out its whole deadline.
            send({"method": "Page.loadEventFired", "params": {}, "sessionId": session})
