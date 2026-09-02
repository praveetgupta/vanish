#!/usr/bin/env python3
"""Vanish engine — local HTTP daemon that injects simulated locations into a
connected iPhone (or a mock device with --mock).

API (JSON):
  GET  /             -> phone-friendly remote control page (works over Wi-Fi with --lan)
  GET  /api/status   -> engine/device/session state (+ remote URL/PIN in --lan mode)
  GET  /api/devices  -> visible devices
  GET  /api/favorites-> favorites saved by the Mac app
  GET  /api/geocode?q= -> place search (OpenStreetMap Nominatim)
  POST /api/spoof    {lat, lon}                      teleport (starts/replaces session)
  POST /api/move     {lat, lon}                      update location in active session
  POST /api/route    {points:[{lat,lon,delay_ms}], loop}  play a timed route
  POST /api/stop     {}                              clear simulation (hardened)
  POST /api/refresh  {}                              rescan for devices
  POST /api/shutdown {}                              stop spoofing and exit cleanly

Run with --lan to allow control from other devices on the network (a PIN is
generated and required for non-local clients; shown in /api/status and the app).
"""

import argparse
import json
import logging
import secrets
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs, urlencode
import urllib.request

log = logging.getLogger("vanish.daemon")

MOCK_DEVICE = {
    "udid": "MOCK-0000-0000",
    "name": "iPhone (Mock)",
    "ios": "17.5",
    "connection": "mock",
}

FAVORITES_PATH = Path.home() / "Library" / "Application Support" / "Vanish" / "favorites.json"


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:  # noqa: BLE001
        return "127.0.0.1"
    finally:
        s.close()


class RoutePlayer(threading.Thread):
    """Plays a timed list of waypoints into the active session."""

    def __init__(self, engine, points, loop):
        super().__init__(daemon=True)
        self.engine = engine
        self.points = points  # [{lat, lon, delay_ms}]
        self.loop = loop
        self.index = 0
        self.total = len(points)
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.is_set():
            for i, p in enumerate(self.points):
                if self.stop_flag.is_set():
                    return
                self.index = i + 1
                lat = p["lat"] + self.engine.jitter() * 0.5
                lon = p["lon"] + self.engine.jitter() * 0.5
                try:
                    self.engine._apply_location(lat, lon)
                except Exception as e:  # noqa: BLE001
                    log.error("route playback failed: %s", e)
                    self.stop_flag.set()
                    self.engine._on_route_error(str(e))
                    return
                self.stop_flag.wait(max(p.get("delay_ms", 1000), 50) / 1000.0)
            if not self.loop:
                return


class Engine:
    def __init__(self, mock: bool):
        self.mock = mock
        self.lock = threading.RLock()
        self.device = MOCK_DEVICE.copy() if mock else None
        self.session = None          # injector session (real mode)
        self.cur = None              # {"lat":…, "lon":…}
        self.kind = None             # teleport | route | joystick
        self.route = None            # RoutePlayer
        self.error = None            # last user-facing error (Hint)
        self.remote = None           # {"url":…, "pin":…} in --lan mode
        self._scan_devices()

    # -- device management ------------------------------------------------
    def _scan_devices(self):
        if self.mock:
            return
        try:
            from injector import real as device_injector
            devices = device_injector.list_devices()
            with self.lock:
                if devices and (self.device is None or not any(
                        d["udid"] == self.device["udid"] for d in devices)):
                    self.device = devices[0]
                    log.info("device found: %s (iOS %s)", self.device["name"], self.device["ios"])
                elif not devices:
                    if self.device and self.session:
                        log.info("device disappeared; clearing session")
                        self._clear_locked()
                    self.device = None
        except Exception as e:  # noqa: BLE001
            log.warning("device scan failed: %s", e)

    def refresh(self):
        self._scan_devices()

    def devices(self):
        if self.mock:
            return [MOCK_DEVICE]
        try:
            from injector import real as device_injector
            return device_injector.list_devices()
        except Exception:  # noqa: BLE001
            return []

    # -- session management -------------------------------------------------
    def _ensure_session(self):
        """Open a real session if needed. Caller holds lock."""
        if self.mock:
            return
        if self.session is None:
            if self.device is None:
                from injector import Hint
                raise Hint("No iPhone detected. Connect it with a cable (and accept "
                           "'Trust this computer'), then press Refresh.")
            from injector import real as device_injector
            self.session = device_injector.open_session(self.device)

    def _apply_location(self, lat: float, lon: float):
        from injector import Hint
        with self.lock:
            if self.mock:
                self.cur = {"lat": lat, "lon": lon}
                return
            try:
                self._ensure_session()
                self.session.set(lat, lon)
                self.cur = {"lat": lat, "lon": lon}   # only record on success
            except Hint:
                raise
            except Exception:
                # stale/broken device connection — drop it so the next attempt re-opens
                self._drop_session_locked()
                raise

    def _drop_session_locked(self):
        if self.session is not None:
            try:
                self.session.close()
            except Exception:  # noqa: BLE001
                pass
            self.session = None

    def spoof(self, lat, lon):
        with self.lock:
            self._stop_route_locked()
            self.kind = "teleport"
            self._apply_location(lat, lon)

    def move(self, lat, lon):
        with self.lock:
            if self.cur is None:
                from injector import Hint
                raise Hint("No active spoof session — teleport somewhere first.")
            if self.kind != "route":
                self.kind = "joystick" if self.kind == "joystick" else "teleport"
            self._apply_location(lat, lon)

    def start_route(self, points, loop):
        with self.lock:
            self._stop_route_locked()
            self.kind = "route"
            self._apply_location(points[0]["lat"], points[0]["lon"])
            self.route = RoutePlayer(self, points, loop)
            self.route.start()

    def _on_route_error(self, msg):
        with self.lock:
            self.error = msg
            self.kind = "teleport"

    def _stop_route_locked(self):
        if self.route and self.route.is_alive():
            self.route.stop_flag.set()
            self.route.join(timeout=2)
        self.route = None

    def stop(self):
        with self.lock:
            self._stop_route_locked()
            self._clear_locked()

    def _clear_locked(self):
        self.cur = None
        self.kind = None
        if self.session is not None:
            try:
                self.session.clear()
            except Exception as e:  # noqa: BLE001
                log.warning("clear failed: %s", e)
            # stopLocationSimulation is fire-and-forget over DTX; give the
            # device a moment to process it before we tear the channel down,
            # otherwise the simulated location sticks.
            time.sleep(0.8)
            try:
                self.session.close()
            except Exception:  # noqa: BLE001
                pass
            self.session = None
            if not self.mock:
                try:
                    from injector import reset_native_tunnel
                    reset_native_tunnel()
                except Exception:  # noqa: BLE001
                    pass

    def startup_rescue(self):
        """Clear a simulated location left over from a previous engine run
        (e.g. after a force-kill), so the phone always wakes up clean."""
        if self.mock:
            return
        self._scan_devices()
        with self.lock:
            device = self.device
        if device is None:
            return
        try:
            from injector import real as device_injector
            session = device_injector.open_session(device)
            session.clear()
            time.sleep(0.5)
            session.close()
            from injector import reset_native_tunnel
            reset_native_tunnel()
            log.info("startup rescue: cleared any lingering simulated location")
        except Exception as e:  # noqa: BLE001
            log.warning("startup rescue skipped: %s", e)

    @staticmethod
    def jitter():
        # ~3–12 m of GPS noise so the dot breathes like a real fix
        import random
        return random.uniform(-0.00008, 0.00008)

    # -- misc ---------------------------------------------------------------
    def favorites(self):
        try:
            data = json.loads(FAVORITES_PATH.read_text())
            return [{"name": f["name"], "lat": f["lat"], "lon": f["lon"]} for f in data]
        except Exception:  # noqa: BLE001
            return []

    def geocode(self, query):
        url = ("https://nominatim.openstreetmap.org/search?" +
               urlencode({"q": query, "format": "json", "limit": 5}))
        req = urllib.request.Request(url, headers={"User-Agent": "vanish-remote/0.1 (personal)"})
        with urllib.request.urlopen(req, timeout=12) as r:
            results = json.loads(r.read())
        return [{"name": x.get("display_name", "?"),
                 "lat": float(x["lat"]), "lon": float(x["lon"])} for x in results]

    # -- status -------------------------------------------------------------
    def status(self):
        with self.lock:
            route = None
            if self.route and (self.route.is_alive() or self.route.index):
                route = {"running": self.route.is_alive(),
                         "index": self.route.index, "total": self.route.total}
            device = {k: v for k, v in (self.device or {}).items() if not k.startswith("_")}
            hint = None
            if self.error:
                hint = self.error
                self.error = None
            elif not self.mock and self.device is None:
                hint = ("No iPhone detected — connect via USB (or the same Wi-Fi with "
                        "'Show this iPhone when on Wi-Fi' enabled), then press Refresh.")
            return {
                "engine": "ok",
                "mode": "mock" if self.mock else "real",
                "device": device,
                "session": None if self.cur is None else {
                    "lat": self.cur["lat"], "lon": self.cur["lon"],
                    "kind": self.kind,
                    "layer": self.session.kind if self.session else ("mock" if self.mock else None),
                },
                "route": route,
                "remote": self.remote,
                "hint": hint,
            }


# --------------------------------------------------------------------------
# Phone remote control page (served at /)
# --------------------------------------------------------------------------

WEB_PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<title>Vanish Remote</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  body { font-family: -apple-system, system-ui, sans-serif; background:#0b0f14; color:#e8edf2;
         margin:0; padding:16px; max-width:520px; margin-inline:auto; }
  h1 { font-size:22px; margin:4px 0 12px; display:flex; align-items:center; gap:8px; }
  .dot { width:10px; height:10px; border-radius:50%; background:#555; }
  .dot.on { background:#30d158; }
  .card { background:#151b23; border-radius:14px; padding:14px; margin-bottom:14px; }
  .card h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:#8b98a5; margin:0 0 10px; }
  button { font-size:16px; border-radius:10px; border:1px solid #2a3542; background:#1c2733;
           color:#e8edf2; padding:12px 14px; width:100%; margin-bottom:8px; }
  button:active { background:#273546; }
  .primary { background:#0a84ff; border-color:#0a84ff; font-weight:600; }
  .danger { background:#3a1218; border-color:#ff453a; color:#ff453a; font-weight:600; }
  input, select { font-size:16px; border-radius:10px; border:1px solid #2a3542; background:#0e141b;
                  color:#e8edf2; padding:12px; width:100%; }
  .row { display:flex; gap:8px; } .row > * { flex:1; }
  .sub { color:#8b98a5; font-size:12px; margin-top:6px; }
  .fav { text-align:left; }
  .grid { display:grid; grid-template-columns:repeat(3,1fr); gap:8px; }
  .grid button { margin:0; padding:16px 0; }
  #status { font-size:14px; line-height:1.4; }
  #msg { color:#ffb340; font-size:13px; min-height:18px; margin-top:4px; }
</style></head>
<body>
<h1><span class="dot" id="dot"></span> Vanish Remote</h1>

<div class="card"><div id="status">Connecting…</div><div id="msg"></div></div>

<div class="card">
  <h2>Teleport</h2>
  <div class="row">
    <input id="q" placeholder="Search a place…">
    <button style="flex:0 0 76px" class="primary" onclick="doSearch()">Go</button>
  </div>
  <div id="results"></div>
</div>

<div class="card"><h2>Favorites</h2><div id="favs">None yet — star pins in the Mac app.</div></div>

<div class="card">
  <h2>Nudge</h2>
  <select id="step">
    <option value="50">50 m</option>
    <option value="200" selected>200 m</option>
    <option value="1000">1 km</option>
  </select>
  <div class="grid" style="margin-top:10px">
    <button onclick="nudge(-1,1)">&#8598;</button><button onclick="nudge(0,1)">&#8593;</button><button onclick="nudge(1,1)">&#8599;</button>
    <button onclick="nudge(-1,0)">&#8592;</button><button onclick="nudge(0,0)">&bull;</button><button onclick="nudge(1,0)">&#8594;</button>
    <button onclick="nudge(-1,-1)">&#8601;</button><button onclick="nudge(0,-1)">&#8595;</button><button onclick="nudge(1,-1)">&#8600;</button>
  </div>
  <div class="sub">Moves the spoofed position. Teleport first.</div>
</div>

<button class="danger" onclick="doStop()">STOP SPOOFING</button>

<script>
// Ask for the PIN only when the engine actually demands one: a local client
// (or an engine started without --lan) is authorized already, so an eager
// prompt would be a dialog in the way for no reason.
let PIN = localStorage.vanishPin || "";
let asking = false;

async function api(path, opts = {}) {
  const r = await fetch(path, {...opts, headers: {"Content-Type": "application/json", "X-Vanish-Pin": PIN}});
  if (r.status === 403) {
    if (!asking) {
      asking = true;
      PIN = prompt(PIN ? "Wrong PIN — enter the PIN shown in the Vanish app"
                       : "Enter the PIN shown in the Vanish app on your Mac") || "";
      localStorage.vanishPin = PIN;
      asking = false;
    }
    throw new Error("PIN required");
  }
  if (!r.ok) { const e = await r.json().catch(() => ({error: "error"})); throw new Error(e.error || r.status); }
  return r.json();
}

function say(t) { document.getElementById("msg").textContent = t || ""; }

async function poll() {
  try {
    const s = await api("/api/status");
    document.getElementById("dot").className = s.session ? "dot on" : "dot";
    const d = s.device && s.device.name ? s.device.name + " · iOS " + s.device.ios : "No device";
    document.getElementById("status").textContent =
      (s.session ? "Spoofing (" + s.session.kind + ") at " + s.session.lat.toFixed(5) + ", " + s.session.lon.toFixed(5) : "Idle — real GPS active") + " — " + d;
  } catch (e) { document.getElementById("status").textContent = "Offline: " + e.message; }
}

async function doSearch() {
  const q = document.getElementById("q").value.trim();
  if (!q) return;
  say("Searching…");
  try {
    const hits = await api("/api/geocode?q=" + encodeURIComponent(q));
    const box = document.getElementById("results");
    box.innerHTML = "";
    hits.forEach(h => {
      const b = document.createElement("button");
      b.className = "fav";
      b.textContent = h.name;
      b.onclick = async () => { await api("/api/spoof", {method: "POST", body: JSON.stringify({lat: h.lat, lon: h.lon})}); say("Spoofing: " + h.name); box.innerHTML = ""; poll(); };
      box.appendChild(b);
    });
    if (!hits.length) say("No results");
    else say("");
  } catch (e) { say("Search failed: " + e.message); }
}

async function loadFavs() {
  try {
    const favs = await api("/api/favorites");
    const box = document.getElementById("favs");
    box.innerHTML = "";
    if (!favs.length) { box.textContent = "None yet — star pins in the Mac app."; return; }
    favs.forEach(f => {
      const b = document.createElement("button");
      b.className = "fav";
      b.textContent = "★ " + f.name;
      b.onclick = async () => { await api("/api/spoof", {method: "POST", body: JSON.stringify({lat: f.lat, lon: f.lon})}); say("Spoofing: " + f.name); poll(); };
      box.appendChild(b);
    });
  } catch (e) {}
}

async function nudge(dx, dy) {
  const s = await api("/api/status");
  if (!s.session) { say("Teleport somewhere first."); return; }
  const step = parseFloat(document.getElementById("step").value);
  const dLat = dy * step / 111320;
  const dLon = dx * step / (111320 * Math.cos(s.session.lat * Math.PI / 180));
  await api("/api/move", {method: "POST", body: JSON.stringify({lat: s.session.lat + dLat, lon: s.session.lon + dLon})});
  poll();
}

async function doStop() {
  await api("/api/stop", {method: "POST", body: "{}"});
  say("Stopped — real GPS restored on next fix.");
  poll();
}

document.getElementById("q").addEventListener("keydown", e => { if (e.key === "Enter") doSearch(); });
loadFavs(); poll(); setInterval(poll, 2500);
</script>
</body></html>"""


class Server(ThreadingHTTPServer):
    def __init__(self, address, handler, lan_mode: bool, pin: str):
        super().__init__(address, handler)
        self.lan_mode = lan_mode
        self.pin = pin


class Handler(BaseHTTPRequestHandler):
    engine: Engine = None  # type: ignore[assignment]

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Vanish-Pin")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self) -> bool:
        if not self.server.lan_mode:  # type: ignore[attr-defined]
            return True
        ip = self.client_address[0]
        if ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
            return True
        if self.headers.get("X-Vanish-Pin") == self.server.pin:  # type: ignore[attr-defined]
            return True
        qs = parse_qs(urlparse(self.path).query)
        return qs.get("pin", [None])[0] == self.server.pin  # type: ignore[attr-defined]

    def log_message(self, fmt, *args):  # quiet
        log.debug("%s " + fmt, self.address_string(), *args)

    def do_OPTIONS(self):
        self._send(200, {})

    def do_GET(self):
        try:
            path = urlparse(self.path).path
            if path == "/":
                body = WEB_PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path == "/api/health":
                self._send(200, {"ok": True})
                return
            if not self._authorized():
                self._send(403, {"error": "PIN required (see the Vanish app on the Mac)"})
                return
            if path == "/api/status":
                self._send(200, self.engine.status())
            elif path == "/api/devices":
                self._send(200, {"devices": self.engine.devices()})
            elif path == "/api/favorites":
                self._send(200, self.engine.favorites())
            elif path == "/api/geocode":
                qs = parse_qs(urlparse(self.path).query)
                q = (qs.get("q") or [""])[0].strip()
                if not q:
                    self._send(400, {"error": "q required"})
                    return
                self._send(200, self.engine.geocode(q))
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": str(e)})

    def do_POST(self):
        try:
            if not self._authorized():
                self._send(403, {"error": "PIN required (see the Vanish app on the Mac)"})
                return
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            if self.path == "/api/spoof":
                self.engine.spoof(float(payload["lat"]), float(payload["lon"]))
                self._send(200, {"ok": True})
            elif self.path == "/api/move":
                self.engine.move(float(payload["lat"]), float(payload["lon"]))
                self._send(200, {"ok": True})
            elif self.path == "/api/route":
                pts = payload.get("points") or []
                if not pts:
                    self._send(400, {"error": "points required"})
                    return
                self.engine.start_route(pts, bool(payload.get("loop", False)))
                self._send(200, {"ok": True})
            elif self.path == "/api/stop":
                self.engine.stop()
                self._send(200, {"ok": True})
            elif self.path == "/api/refresh":
                self.engine.refresh()
                self._send(200, self.engine.status())
            elif self.path == "/api/shutdown":
                self.engine.stop()
                self._send(200, {"ok": True})
                import os
                threading.Timer(0.3, os._exit, args=(0,)).start()
            else:
                self._send(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            # Hints carry user-facing messages; everything else is a bug but we
            # still surface it rather than hanging the UI.
            self._send(400, {"error": str(e)})


def main():
    import signal
    import sys

    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--mock", action="store_true", help="run against a fake device")
    ap.add_argument("--lan", action="store_true",
                    help="allow control from other devices on the network (PIN-protected)")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")

    engine = Engine(mock=args.mock)
    Handler.engine = engine

    pin = f"{secrets.randbelow(1000000):06d}"
    if args.lan:
        engine.remote = {"url": f"http://{lan_ip()}:{args.port}", "pin": pin}
        log.info("remote control enabled: %s  (PIN %s)", engine.remote["url"], pin)

    def _on_sigterm(_sig, _frame):
        log.info("SIGTERM; clearing simulation…")
        engine.stop()
        sys.exit(0)
    signal.signal(signal.SIGTERM, _on_sigterm)

    # clean up any simulation a previous engine run left on the device
    engine.startup_rescue()

    # periodic device rescan so the app notices plug/unplug without a manual refresh
    def scanner():
        while True:
            time.sleep(10)
            engine.refresh()
    threading.Thread(target=scanner, daemon=True).start()

    address = "0.0.0.0" if args.lan else "127.0.0.1"
    server = Server((address, args.port), Handler, lan_mode=args.lan, pin=pin)
    log.info("Vanish engine listening on %s:%d (mode=%s)", address, args.port, engine.status()["mode"])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down; clearing simulation…")
        engine.stop()


if __name__ == "__main__":
    main()
