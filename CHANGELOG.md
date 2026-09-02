# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-09-02

First public release.

### Added

- **Mac app** (SwiftUI, macOS 14+) with a MapKit map: click to drop a pin, search places
  through Apple Maps autocomplete plus a direct-search fallback, and teleport.
- **Route simulation** — Apple Maps directions converted to timed waypoints, played at
  walking, cycling or driving speed with per-tick speed variation and GPS jitter, with
  live waypoint progress and the route drawn on the map.
- **Joystick** — eight-way nudging of the spoofed position at 50 m, 200 m, 1 km or 5 km.
- **Favorites**, saved to `~/Library/Application Support/Vanish/favorites.json` and shared
  with the menu bar and the phone remote.
- **Menu-bar extra** with status, one-click favorite teleports, stop, and a
  *Quit & Stop Spoofing* action that hands the real GPS back on the way out.
- **Local HTTP engine** (`engine/daemon.py`) that owns the device connection and exposes the
  whole feature set as JSON on `127.0.0.1:8799`.
- **Four injection pathways** tried in order — lockdown `com.apple.dt.simulatelocation`,
  DVT Instruments over usbmux, DVT over a native `remotepairingd` tunnel (iOS 17+, no root),
  and DVT over `tunneld` — with the per-layer failure detail surfaced as a hint in the app.
- **Phone remote** — `--lan` serves a mobile web page with status, search, favorites, a nudge
  pad and a stop button, protected by a PIN regenerated at every engine start.
- **CLI** (`engine/cli.py`) — status, devices, teleport by name or coordinate, move, stop.
- **Mock mode** (`--mock`) so the entire app is usable and testable with no iPhone attached.
- **Startup rescue** that clears a simulated location left behind by a force-killed engine,
  so the phone never gets stuck somewhere.
- Clean session teardown: the simulation is cleared, the DTX channel is given time to process
  it, and the native tunnel is torn down so iOS falls back to its real GPS.
