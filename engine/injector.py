"""Real-device injection layer for the Vanish engine (pymobiledevice3 v11).

pymobiledevice3 v11 is asyncio-based; this module owns one background asyncio
loop and exposes plain sync methods the threaded HTTP daemon can call.

Strategy order (first that opens wins):

  A. Lockdown "com.apple.dt.simulatelocation" (DtSimulateLocation)
     - fresh device connection per set/clear, nothing to keep alive
     - usually works without Developer Mode on iOS <= 16
  B. DVT Instruments LocationSimulation over usbmux lockdown
     - persistent DTX channel; needs Developer Mode on iOS 16+
  C. DVT over an RSD tunnel (iOS 17+)
     - needs `sudo pymobiledevice3 remote tunneld` running

Failures raise Hint with a message meant for the app UI.
"""

import asyncio
import logging
import threading

log = logging.getLogger("vanish.injector")


class Hint(Exception):
    """A failure whose message is safe/useful to show to the user."""


# --------------------------------------------------------------------------
# Transports (sync facade over the asyncio loop)
# --------------------------------------------------------------------------

class LockdownTransport:
    kind = "lockdown"

    def __init__(self, real, lockdown, sim):
        self._real = real
        self._lockdown = lockdown
        self._sim = sim

    def set(self, lat: float, lon: float):
        async def _go():
            await self._sim.set(latitude=lat, longitude=lon)
        self._real.run(_go(), 20)

    def clear(self):
        self._real.run(self._sim.clear(), 20)

    def close(self):
        try:
            self._real.run(self._lockdown.close(), 10)
        except Exception:  # noqa: BLE001
            pass


class DvtTransport:
    kind = "dvt"

    def __init__(self, real, provider, sim):
        self._real = real
        self._provider = provider
        self._sim = sim

    def set(self, lat: float, lon: float):
        async def _go():
            await self._sim.set(latitude=lat, longitude=lon)
        self._real.run(_go(), 20)

    def clear(self):
        self._real.run(self._sim.clear(), 20)

    def close(self):
        async def _go():
            for obj in (self._sim, self._provider):
                closer = getattr(obj, "__aexit__", None)
                if closer:
                    try:
                        await closer(None, None, None)
                    except Exception:  # noqa: BLE001
                        pass
        try:
            self._real.run(_go(), 10)
        except Exception:  # noqa: BLE001
            pass


# --------------------------------------------------------------------------
# RealInjector — owns the asyncio loop
# --------------------------------------------------------------------------

class RealInjector:
    def __init__(self):
        self._loop = asyncio.new_event_loop()
        threading.Thread(target=self._loop.run_forever, daemon=True,
                         name="pymobiledevice3-loop").start()

    def run(self, coro, timeout=30):
        fut = asyncio.run_coroutine_threadsafe(coro, self._loop)
        return fut.result(timeout)

    # ---- discovery -------------------------------------------------------
    def list_devices(self):
        return self.run(self._list_devices(), 25)

    async def _list_devices(self):
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.usbmux import list_devices as usbmux_list

        out = []
        try:
            mux_devices = await usbmux_list()
        except Exception as e:  # noqa: BLE001
            log.debug("usbmux listing failed: %s", e)
            mux_devices = []

        for dev in mux_devices:
            serial = getattr(dev, "serial", None) or getattr(dev, "udid", None)
            if not serial:
                continue
            try:
                lockdown = await create_using_usbmux(serial=serial)
                try:
                    info = lockdown.short_info  # property in v11
                    out.append({
                        "udid": serial,
                        "name": info.get("DeviceName", "iPhone"),
                        "ios": str(info.get("ProductVersion", "?")),
                        "connection": "usb",
                    })
                finally:
                    try:
                        await lockdown.close()
                    except Exception:  # noqa: BLE001
                        pass
            except Exception as e:  # noqa: BLE001
                log.warning("device %s not pairable yet: %s", serial, e)

        # iOS 17+ tunnels (visible when `sudo pymobiledevice3 remote tunneld` runs)
        try:
            from pymobiledevice3.remote.utils import get_rsds
            for rsd in await get_rsds():
                info = getattr(rsd, "peer_info", {}) or {}
                props = info.get("Properties", {}) if isinstance(info, dict) else {}
                out.append({
                    "udid": getattr(rsd, "udid", None) or props.get("UniqueDeviceID", "?"),
                    "name": getattr(rsd, "name", None) or props.get("DeviceName", "iPhone (tunnel)"),
                    "ios": str(getattr(rsd, "product_version", "") or props.get("ProductVersion", "?")),
                    "connection": "tunnel",
                    "_rsd": rsd,
                })
        except Exception as e:  # noqa: BLE001
            log.debug("tunnel scan failed (normal without tunneld): %s", e)

        seen = set()
        deduped = []
        for d in out:
            if d["udid"] in seen:
                continue
            seen.add(d["udid"])
            deduped.append(d)
        return deduped

    # ---- sessions --------------------------------------------------------
    def open_session(self, device):
        return self.run(self._open_session(device), 30)

    async def _open_session(self, device):
        from pymobiledevice3.lockdown import create_using_usbmux
        errors = []

        if device.get("connection") == "usb":
            # A) lockdown com.apple.dt.simulatelocation — fresh conn per command
            try:
                lockdown = await create_using_usbmux(serial=device["udid"])
                from pymobiledevice3.services.simulate_location import DtSimulateLocation
                sim = DtSimulateLocation(lockdown)
                await sim.clear()  # probe: validates the developer service opens
                log.info("session layer: lockdown (com.apple.dt.simulatelocation)")
                return LockdownTransport(self, lockdown, sim)
            except Exception as e:  # noqa: BLE001
                errors.append(f"lockdown: {type(e).__name__}: {e}")

            # B) DVT instruments over usbmux
            try:
                lockdown = await create_using_usbmux(serial=device["udid"])
                from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
                from pymobiledevice3.services.dvt.instruments.location_simulation import (
                    LocationSimulation,
                )
                provider = DvtProvider(lockdown)
                await provider.__aenter__()
                sim = LocationSimulation(provider)
                await self._maybe_enter(sim)
                log.info("session layer: DVT over usbmux")
                return DvtTransport(self, provider, sim)
            except Exception as e:  # noqa: BLE001
                errors.append(f"dvt-usbmux: {type(e).__name__}: {e}")

            # C) native tunnel via Apple's remotepairingd — macOS only,
            #    iOS 17+, no root needed (piggybacks the same daemon Xcode uses)
            import platform
            if platform.system() == "Darwin":
                try:
                    from pymobiledevice3.remote import native_tunnel
                    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
                    from pymobiledevice3.services.dvt.instruments.location_simulation import (
                        LocationSimulation,
                    )
                    rsd = await native_tunnel.establish_native_rsd(serial=device["udid"])
                    provider = DvtProvider(rsd)
                    await provider.__aenter__()
                    sim = LocationSimulation(provider)
                    await self._maybe_enter(sim)
                    log.info("session layer: DVT over native tunnel (no root)")
                    return DvtTransport(self, provider, sim)
                except Exception as e:  # noqa: BLE001
                    errors.append(f"native-tunnel: {type(e).__name__}: {e}")

        if device.get("connection") == "tunnel":
            # C) DVT over RSD tunnel (iOS 17+ with tunneld)
            rsd = device.get("_rsd")
            if rsd is not None:
                try:
                    from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
                    from pymobiledevice3.services.dvt.instruments.location_simulation import (
                        LocationSimulation,
                    )
                    provider = DvtProvider(rsd)
                    await provider.__aenter__()
                    sim = LocationSimulation(provider)
                    await self._maybe_enter(sim)
                    log.info("session layer: DVT over tunnel")
                    return DvtTransport(self, provider, sim)
                except Exception as e:  # noqa: BLE001
                    errors.append(f"dvt-tunnel: {type(e).__name__}: {e}")

        raise Hint(
            "Could not open a location-simulation session. Checklist: "
            "(1) iPhone unlocked and 'Trust this computer' accepted, "
            "(2) Developer Mode ON (Settings > Privacy & Security > Developer Mode), "
            "(3) on iOS 17+ run `sudo pymobiledevice3 remote tunneld` in a terminal. "
            "Details: " + " | ".join(errors)
        )

    @staticmethod
    async def _maybe_enter(sim):
        aenter = getattr(sim, "__aenter__", None)
        if aenter is None:
            return
        try:
            await aenter()
        except TypeError:
            pass  # not an async context manager after all


# Singleton used by the daemon
real = RealInjector()


def reset_native_tunnel():
    """Fully close the process-lifetime native tunnel (if open).

    iOS may keep connection-bound simulation state alive until the remotepairingd
    session drops — this is the "unplug the cable" equivalent, guaranteeing the
    device falls back to its real GPS after a stop.
    """
    try:
        from pymobiledevice3.remote import native_tunnel
        tunnel = getattr(native_tunnel, "_cli_native_tunnel", None)
        if tunnel is None:
            return
        native_tunnel._cli_native_tunnel = None  # detach memo so next use re-opens

        async def _close():
            await tunnel.aclose()
        real.run(_close(), 15)
        log.info("native tunnel torn down")
    except Exception as e:  # noqa: BLE001
        log.debug("native tunnel teardown: %s", e)
