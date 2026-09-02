# Contributing

Thanks for taking a look. Vanish is two small pieces — a SwiftUI app and a single-file Python
engine — with one third-party dependency between them, so most changes are easy to review.

## Getting set up

```bash
git clone https://github.com/praveetgupta/vanish.git
cd vanish
./scripts/make_app.sh          # creates the venv, installs deps, builds Vanish.app
```

You do not need an iPhone to work on most of this:

```bash
engine/venv/bin/python engine/daemon.py --mock --verbose
open Vanish.app
```

Mock mode accepts every command and reports a fake device, so the map, routes, joystick,
favorites, phone remote and CLI are all exercisable with nothing plugged in. Anything that
touches `engine/injector.py` does need a real device, since that is the only part that speaks
to hardware.

To iterate on the Swift side without rebundling:

```bash
cd app && swift build && VANISH_ENGINE_DIR=../engine ./.build/debug/Vanish
```

## Before opening a pull request

- `swift build` produces no warnings. The app is warning-clean today; please keep it that way.
- `python -m compileall engine` passes, and the daemon still starts in `--mock`.
- Exercise what you changed against mock mode at minimum, and say in the PR whether you were
  able to test on a real device — and on which iOS version, because the four injection
  pathways behave very differently across them.
- Match the surrounding style: no dependencies beyond `pymobiledevice3`, and comments that
  explain *why* rather than restating the code.

## Reporting a bug

Please include:

- macOS version and iPhone iOS version
- whether the phone was on USB or Wi-Fi
- which layer the session opened on (the status bar shows `layer: lockdown` / `dvt` / `mock`)
- the engine log — run it in the foreground with `--verbose` and paste the relevant part
- the full text of any hint banner, since it carries the per-layer failure detail

Redact your UDID and LAN addresses if you would rather not share them; they are almost never
needed to reproduce a problem.

## Things that would help

- Reading the phone's actual reported location back, so the app can confirm the fix landed
  rather than assuming the write succeeded.
- Altitude, speed and course, which `LocationSimulation` accepts but Vanish does not expose.
- Recording and replaying a route from a GPX file.
- Linux support. The engine is portable in principle; pathway 3 is macOS-only, but the other
  three are not.
