# Architecture

Vanish is deliberately split in two. The Swift app never touches the phone; the Python engine
never draws anything. They meet at one local HTTP API, which is also what makes the CLI and the
phone remote possible without any extra code.

```
Vanish.app (SwiftUI)          engine/daemon.py            engine/injector.py       iPhone
──────────────────────────────────────────────────────────────────────────────────────────
AppState  ──HTTP──▶  Handler ──▶  Engine  ──▶  RealInjector  ──▶  lockdown / DVT
   ▲                                │                                    │
   └──── status poll (1.2 s) ───────┘                                    ▼
                                                                   simulated fix
```

## Why a separate engine process

`pymobiledevice3` is Python, asyncio-based, and the only practical way to speak lockdown and
DTX from userland. Rather than bridge that into Swift, the engine stays a process of its own,
which buys three things:

- **The session outlives the UI.** Closing the window, or the app crashing, does not drop the
  device connection mid-route.
- **One owner of the device.** Exactly one process holds the DTX channel, so there is no way to
  get two conflicting sessions.
- **Every client is equal.** The Mac app, `cli.py` and the phone's browser all speak the same
  JSON. Nothing has a privileged back door.

The app spawns the engine itself (`EngineLauncher.ensureRunning`) and polls `/api/status` every
1.2 seconds, so the UI is always reporting device truth rather than what it last asked for.

## Finding the engine

`EngineLauncher.engineDir` looks in order at: a `engineDir` user default, `VANISH_ENGINE_DIR`
in the environment, `Vanish.app/Contents/Resources/engine` in the shipped bundle, and finally an
`engine/` directory beside any ancestor of the running executable — which is what makes
`swift run` work straight out of a checkout without configuration.

## Threading

The daemon is a `ThreadingHTTPServer`, so requests are concurrent, but all device state sits
behind a single `threading.RLock` on `Engine`. `pymobiledevice3` v11 is asyncio, so
`RealInjector` owns one background event loop for the process lifetime and exposes plain
synchronous methods via `run_coroutine_threadsafe`. Threaded HTTP handlers therefore never see
a coroutine.

Route playback is a `RoutePlayer` thread that calls back into `Engine._apply_location` for each
waypoint, taking the same lock as everything else. It is stopped by an `Event`, so starting a
new route or a teleport cleanly pre-empts a running one.

A background scanner thread re-checks for devices every 10 seconds, which is how plugging or
unplugging the phone shows up without pressing refresh.

## Sessions and failure

`_open_session` tries the four pathways in order and returns the first transport that opens
(`LockdownTransport` or `DvtTransport`, both exposing `set` / `clear` / `close`). Each failure
is collected rather than swallowed; if all four fail, the accumulated detail is raised as a
`Hint`, which is the exception class whose message is safe to put in front of a user. The app
renders any `hint` from `/api/status` as a banner over the map.

Location writes are transactional in one specific sense: `Engine.cur` is only updated *after*
the write succeeds, so the UI can never show a fake position the phone did not accept. Any
non-`Hint` exception drops the session so the next attempt re-opens it, which is what makes the
app recover by itself from a sleeping phone or a yanked cable.

## Stopping cleanly

Handing back the real GPS takes more than closing the socket:

1. `session.clear()` sends `stopLocationSimulation`.
2. Sleep 800 ms — the DTX call is fire-and-forget, and tearing the channel down immediately
   leaves the simulated location stuck on the device.
3. Close the transport.
4. `reset_native_tunnel()` drops the process-lifetime `remotepairingd` tunnel. iOS can keep
   connection-bound simulation state alive until that session ends, so this is the "unplug the
   cable" equivalent.

The same path runs on `SIGTERM` and on `KeyboardInterrupt`. For the case where none of it ran —
a `kill -9` — `startup_rescue()` opens a session at the next start purely to clear it.

## The LAN remote

`--lan` binds `0.0.0.0` and generates a six-digit PIN. `_authorized()` lets through anything
from loopback and requires the PIN in an `X-Vanish-Pin` header or a `pin=` query parameter from
anywhere else. `/` (the page) and `/api/health` are deliberately open, since they carry nothing;
every endpoint that reads or changes state is gated.

The PIN is regenerated on every engine start, so it is a session token rather than a password.
This is a convenience feature for your own network, not a security boundary — the transport is
plain HTTP. Without `--lan` the engine binds loopback only and nothing on the network can reach
it at all.

## Route generation

`RoutePlanner.plan` asks `MKDirections` for a real route and falls back to a straight line when
there is none. `interpolate` then walks the polyline emitting a point roughly every
`speed × tick` metres, with the step scaled by a random 0.85–1.15 per tick, the delay scaled by
0.9–1.15, and a few metres of coordinate wobble. The engine adds its own jitter on top at
playback. The result is a trace that varies the way a real GPS fix does instead of advancing in
perfectly uniform steps.
