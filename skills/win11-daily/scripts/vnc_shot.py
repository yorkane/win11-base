#!/usr/bin/env python3
"""Grab one full-screen frame from a dockurr/windows container over noVNC (RFB).

usage: vnc_shot.py [ws_url] [out_png]
env:   WIN11_VNC_PORT = host-published VNC port (default 18006 = win11-daily
       fixed family; w11-test=19006). ws_url defaults to
       ws://127.0.0.1:<WIN11_VNC_PORT>/websockify, out_png to /tmp/win11-shot.png

Why VNC and not RDP for screenshots: RDP steals the console session and locks the
local screen, so an RDP capture of "the desktop" is actually a lock screen. This
script is read-only: one RFB handshake, one FramebufferUpdate, no input injected.
"""
import struct
import sys
import time

import websocket

import os
VNC_PORT = os.environ.get("WIN11_VNC_PORT", "18006")
URL = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "ws://127.0.0.1:" + VNC_PORT + "/websockify"
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/win11-shot.png"

ws = websocket.WebSocket()
ws.connect(URL, timeout=15, subprotocols=["binary"])
buf = b""


def rd(n, t=5):
    global buf
    ws.settimeout(t)
    deadline = time.time() + t
    while len(buf) < n and time.time() < deadline:
        try:
            f = ws.recv_frame()
        except Exception:
            return False
        if f is None:
            break
        buf += f.data
    return len(buf) >= n


rd(12); buf = buf[12:]
ws.send_binary(b"RFB 003.008\n")
rd(2); buf = buf[2:]
ws.send_binary(b"\x01")
rd(4); buf = buf[4:]
ws.send_binary(b"\x01")

if not rd(24, 5):
    print("init too short: %s bytes" % len(buf)); sys.exit(1)
w = struct.unpack(">H", buf[:2])[0]
h = struct.unpack(">H", buf[2:4])[0]
buf = buf[4:]
buf = buf[16:]                      # pixel format
name_len = struct.unpack(">I", buf[:4])[0]; buf = buf[4:]
print("size %sx%s" % (w, h))
rd(name_len, 5); buf = buf[name_len:]

ws.send_binary(b"\x03\x00\x00\x00\x00\x00" + struct.pack(">HH", w, h))

ws.settimeout(25)
pixels = bytearray()
rect_count = 0
deadline = time.time() + 25
try:
    while time.time() < deadline:
        while len(buf) < 4:
            try:
                f = ws.recv_frame()
            except Exception:
                break
            if f is None:
                break
            buf += f.data
        if len(buf) < 4:
            break
        if buf[0] != 0:
            print("unexpected message type %s" % buf[0]); break
        n_rects = struct.unpack(">H", buf[2:4])[0]
        buf = buf[4:]
        for _ in range(n_rects):
            while len(buf) < 12:
                try:
                    f = ws.recv_frame()
                except Exception:
                    break
                if f is None:
                    break
                buf += f.data
            if len(buf) < 12:
                break
            rw = struct.unpack(">h", buf[4:6])[0]
            rh = struct.unpack(">h", buf[6:8])[0]
            etype = struct.unpack(">I", buf[8:12])[0]
            buf = buf[12:]
            if etype != 0:
                print("unsupported encoding %s" % etype); break
            need = rw * rh * 4
            while len(buf) < need:
                try:
                    f = ws.recv_frame()
                except Exception:
                    break
                if f is None:
                    break
                buf += f.data
            pixels += buf[:need]; buf = buf[need:]
            rect_count += 1
        break
except Exception as exc:
    print("err: %s" % exc)

print("pixels %s expected %s rects %s" % (len(pixels), w * h * 4, rect_count))
if len(pixels) >= w * h * 4:
    from PIL import Image
    Image.frombytes("RGBA", (w, h), bytes(pixels[:w * h * 4]), "raw", "BGRA").save(OUT)
    print("saved " + OUT)
else:
    sys.exit(1)
ws.close()
