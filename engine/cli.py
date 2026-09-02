#!/usr/bin/env python3
"""vanish — command-line companion to the Vanish engine.

  cli.py status                     show engine/device/session state
  cli.py devices                    list visible iPhones
  cli.py teleport "Eiffel Tower"    geocode a place and teleport
  cli.py teleport --lat 48.8584 --lon 2.2945
  cli.py move --lat 48.86 --lon 2.30
  cli.py stop                       end the spoof session

Requires the engine to be running (the Vanish app starts it automatically).
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:8799"


def _get(path):
    with urllib.request.urlopen(BASE + path, timeout=10) as r:
        return json.loads(r.read())


def _post(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def geocode(query):
    """Resolve a place name via OpenStreetMap Nominatim (light personal use)."""
    url = ("https://nominatim.openstreetmap.org/search?" +
           urllib.parse.urlencode({"q": query, "format": "json", "limit": 1}))
    req = urllib.request.Request(url, headers={"User-Agent": "vanish-cli/0.1 (personal)"})
    with urllib.request.urlopen(req, timeout=15) as r:
        results = json.loads(r.read())
    if not results:
        sys.exit(f"Could not geocode: {query}")
    return float(results[0]["lat"]), float(results[0]["lon"]), results[0]["display_name"]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="engine/device/session state")
    sub.add_parser("devices", help="list visible iPhones")

    tp = sub.add_parser("teleport", help="spoof a fixed location")
    tp.add_argument("place", nargs="?", help='place name, e.g. "Eiffel Tower"')
    tp.add_argument("--lat", type=float)
    tp.add_argument("--lon", type=float)

    mv = sub.add_parser("move", help="move the spoofed position")
    mv.add_argument("--lat", type=float, required=True)
    mv.add_argument("--lon", type=float, required=True)

    sub.add_parser("stop", help="end spoofing")

    args = ap.parse_args()

    try:
        if args.cmd == "status":
            print(json.dumps(_get("/api/status"), indent=2))
        elif args.cmd == "devices":
            print(json.dumps(_get("/api/devices"), indent=2))
        elif args.cmd == "teleport":
            if args.place:
                lat, lon, name = geocode(args.place)
                print(f"Resolved: {name}")
            elif args.lat is not None and args.lon is not None:
                lat, lon = args.lat, args.lon
            else:
                sys.exit("Give a place name or --lat/--lon.")
            _post("/api/spoof", {"lat": lat, "lon": lon})
            print(f"Spoofing: {lat:.5f}, {lon:.5f}")
        elif args.cmd == "move":
            _post("/api/move", {"lat": args.lat, "lon": args.lon})
            print(f"Moved to: {args.lat:.5f}, {args.lon:.5f}")
        elif args.cmd == "stop":
            _post("/api/stop", {})
            print("Spoofing stopped.")
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        try:
            message = json.loads(body).get("error", body)
        except Exception:  # noqa: BLE001
            message = body
        sys.exit(f"Engine error: {message}")
    except urllib.error.URLError:
        sys.exit("Engine not reachable on 127.0.0.1:8799 — open the Vanish app first.")


if __name__ == "__main__":
    main()
