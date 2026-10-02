#!/usr/bin/env python3
"""bridge.py -- live UI bridge between the rt sim (TCP) and a browser (HTTP).

    python3 doom/rt/bridge.py --sim-port 7777 --http-port 8080 \
        --wad doom/freedoom1.wad

Serves:
    /               live player page (doom/rt/ui.html)
    /api/palette    PLAYPAL lump (768 raw bytes)
    /api/state      JSON: latest frame (base64 indices) + measured stats
    POST /api/key   {"key": <doomkeys byte>, "pressed": bool}

Stats (MHz, tics/s, CPI) are measured here from frame header cycle stamps
and arrival times -- same method as the sim's own [rt] lines.
"""
import argparse
import base64
import json
import socket
import struct
import threading
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FB_W, FB_H = 320, 200
FB_BYTES = FB_W * FB_H  # 64000 raw palette indices per frame


def playpal(wad_path):
    with open(wad_path, "rb") as f:
        magic, nlumps, dirofs = struct.unpack("<4sII", f.read(12))
        assert magic in (b"IWAD", b"PWAD"), "not a WAD"
        f.seek(dirofs)
        for _ in range(nlumps):
            ofs, size, name = struct.unpack("<II8s", f.read(16))
            if name.rstrip(b"\0") == b"PLAYPAL":
                f.seek(ofs)
                return f.read(768)
    raise SystemExit(f"{wad_path}: no PLAYPAL lump")


class SimLink:
    """Owns the TCP connection to sim_rt (+live). Reader thread keeps the
    latest frame/console cached; request threads only touch the cache."""

    def __init__(self, port):
        self.port = port
        self.sock = None
        self.send_lock = threading.Lock()
        self.lock = threading.Lock()
        self.frame_n = -1
        self.frame_cyc = 0
        self.frame_instret = 0
        self.frame_data = bytes(FB_BYTES)
        self.frame_at = 0.0
        self.prev_cyc = 0
        self.prev_at = 0.0
        self.mhz = 0.0
        self.tps = 0.0
        self.cpi = 0.0
        self.console = deque(maxlen=4000)  # chars
        self.connected = False
        self.ended = False

    def run(self):
        while True:
            try:
                s = socket.create_connection(("127.0.0.1", self.port),
                                             timeout=5)
                s.settimeout(2.0)
            except OSError:
                time.sleep(0.5)
                continue
            self.sock = s
            with self.lock:
                self.connected = True
            print(f"[bridge] connected to sim :{self.port}", flush=True)
            try:
                self._reader_loop(s)
            except OSError as e:
                print(f"[bridge] sim link dropped: {e}", flush=True)
            with self.lock:
                self.connected = False
                self.ended = True
            try:
                s.close()
            except OSError:
                pass
            self.sock = None
            return  # sim runs once; serve cached state until restart

    def _send(self, data):
        with self.send_lock:
            if self.sock is not None:
                try:
                    self.sock.sendall(data)
                except OSError:
                    pass

    def send_key(self, key, pressed):
        self._send(bytes((0x4B, key & 0xFF, 1 if pressed else 0)))  # 'K'

    def _reader_loop(self, s):
        buf = bytearray()
        last_g = 0.0
        while True:
            now = time.time()
            if now - last_g > 0.25:  # poll for latest frame
                self._send(b"G")
                last_g = now
            try:
                chunk = s.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                return
            buf += chunk
            while True:
                if not buf:
                    break
                tag = buf[0]
                if tag == 0x46:  # 'F' + u32 n + u64 cyc + u64 instret + frame
                    if len(buf) < 21 + FB_BYTES:
                        break
                    n, cyc, instret = struct.unpack_from("<IQQ", buf, 1)
                    data = bytes(buf[21:21 + FB_BYTES])
                    del buf[:21 + FB_BYTES]
                    at = time.time()
                    with self.lock:
                        if n != self.frame_n and self.frame_n >= 0:
                            dt = at - self.frame_at
                            if dt > 0:
                                dc = cyc - self.frame_cyc
                                self.mhz = dc / dt / 1e6
                                self.tps = (n - self.frame_n) / dt
                                di = instret - self.frame_instret
                                self.cpi = dc / di if di else 0.0
                        self.frame_n = n
                        self.frame_cyc = cyc
                        self.frame_instret = instret
                        self.frame_data = data
                        self.frame_at = at
                elif tag == 0x43:  # 'C' + u16 len + bytes
                    if len(buf) < 3:
                        break
                    (ln,) = struct.unpack_from("<H", buf, 1)
                    if len(buf) < 3 + ln:
                        break
                    text = bytes(buf[3:3 + ln]).decode("utf-8",
                                                       errors="replace")
                    del buf[:3 + ln]
                    with self.lock:
                        self.console.extend(text)
                else:
                    del buf[0]  # resync

    def snapshot(self):
        with self.lock:
            tail = "".join(self.console)[-3000:]
            return {
                "n": self.frame_n,
                "cyc": self.frame_cyc,
                "instret": self.frame_instret,
                "mframes": self.frame_n + 1 if self.frame_n >= 0 else 0,
                "mhz": round(self.mhz, 2),
                "tps": round(self.tps, 2),
                "cpi": round(self.cpi, 4),
                "ipc": round(1 / self.cpi, 4) if self.cpi else 0.0,
                "connected": self.connected,
                "ended": self.ended,
                "frame_b64": base64.b64encode(self.frame_data).decode(),
                "console": tail,
            }


LINK = None
PAL = b""
UI_PATH = ""


class Handler(BaseHTTPRequestHandler):
    server_version = "doom-rt/1.0"

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/":
            body = open(UI_PATH, "rb").read()
            self._send(200, "text/html", body)
        elif path == "/api/palette":
            self._send(200, "application/octet-stream", PAL)
        elif path == "/api/state":
            body = json.dumps(LINK.snapshot()).encode()
            self._send(200, "application/json", body)
        else:
            self._send(404, "text/plain", b"not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/api/key":
            return self._send(404, "text/plain", b"not found")
        ln = int(self.headers.get("Content-Length", "0"))
        try:
            msg = json.loads(self.rfile.read(ln) or b"{}")
            LINK.send_key(int(msg["key"]), bool(msg["pressed"]))
            self._send(200, "application/json", b'{"ok":true}')
        except (KeyError, ValueError, TypeError):
            self._send(400, "application/json", b'{"ok":false}')

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    global LINK, PAL, UI_PATH
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim-port", type=int, default=7777)
    ap.add_argument("--http-port", type=int, default=8080)
    ap.add_argument("--wad", required=True)
    ap.add_argument("--ui", default="doom/rt/ui.html")
    a = ap.parse_args()

    PAL = playpal(a.wad)
    UI_PATH = a.ui
    LINK = SimLink(a.sim_port)
    threading.Thread(target=LINK.run, daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", a.http_port), Handler)
    print(f"[bridge] UI on 0.0.0.0:{a.http_port}  (wad PLAYPAL ok)", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
