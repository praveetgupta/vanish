import Foundation
import CoreLocation
import Observation

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var status: EngineStatus?
    var engineOnline = false
    var booting = true
    var pin: CLLocationCoordinate2D?                 // map pin / pending target
    var pinName: String?
    var favorites: [Favorite] = FavoriteStore.load()
    var routePreview: [CLLocationCoordinate2D] = []
    var routeNotice: String?
    var errorMessage: String?
    var followFake = true
    var lastStoppedAt: Date?

    var fakeCoord: CLLocationCoordinate2D? {
        guard let s = status?.session else { return nil }
        return CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
    }

    var isSpoofing: Bool { status?.session != nil }
    var isRouteRunning: Bool { status?.route?.running == true }

    var statusText: String {
        guard let status else { return engineOnline ? "Engine starting…" : "Engine offline" }
        if let session = status.session {
            let kind = session.kind.map { " (\($0))" } ?? ""
            return "Spoofing\(kind) · \(status.mode)"
        }
        if let device = status.device {
            return "\(device.name) · iOS \(device.ios) · idle"
        }
        return status.mode == "mock" ? "Mock mode · idle" : "No iPhone detected"
    }

    // MARK: Actions

    func boot() async {
        booting = true
        await EngineLauncher.ensureRunning()
        await refreshStatus()
        booting = false
    }

    func refreshStatus() async {
        do {
            status = try await EngineAPI.status()
            engineOnline = true
        } catch {
            engineOnline = false
        }
    }

    func rescan() async {
        do {
            try await EngineAPI.refresh()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func spoof(to coordinate: CLLocationCoordinate2D, name: String? = nil) async {
        do {
            try await EngineAPI.spoof(lat: coordinate.latitude, lon: coordinate.longitude)
            pin = coordinate
            pinName = name
            routePreview = []
            routeNotice = nil
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            await refreshStatus()
        }
    }

    func stop() async {
        do {
            try await EngineAPI.stop()
            routePreview = []
            routeNotice = nil
            lastStoppedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    func startRoute(to destination: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D?, mode: TravelMode) async {
        guard let source = origin ?? fakeCoord ?? pin else {
            errorMessage = "Pick a starting point first — teleport somewhere or drop a map pin."
            return
        }
        do {
            let plan = await RoutePlanner.plan(from: source, to: destination, mode: mode)
            routePreview = plan.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            routeNotice = plan.count < 2 ? "Route too short to simulate." : nil
            guard plan.count >= 2 else { return }
            try await EngineAPI.route(points: plan, loop: false)
            await refreshStatus()
        } catch {
            errorMessage = "Route failed: \(error.localizedDescription)"
            await refreshStatus()
        }
    }

    func nudge(dxMeters: Double, dyMeters: Double) async {
        guard let current = fakeCoord ?? pin else {
            errorMessage = "Teleport somewhere first — the joystick moves the spoofed position."
            return
        }
        let dLat = dyMeters / 111_320.0
        let dLon = dxMeters / (111_320.0 * max(cos(current.latitude * .pi / 180), 0.01))
        let next = CLLocationCoordinate2D(latitude: current.latitude + dLat,
                                          longitude: current.longitude + dLon)
        await move(to: next)
    }

    func move(to coordinate: CLLocationCoordinate2D) async {
        do {
            try await EngineAPI.move(lat: coordinate.latitude, lon: coordinate.longitude)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Remote (control from the iPhone over Wi-Fi)

    var lanMode = UserDefaults.standard.bool(forKey: "lanMode")

    func setLanMode(_ enabled: Bool) {
        lanMode = enabled
        UserDefaults.standard.set(enabled, forKey: "lanMode")
        Task { await restartEngine() }
    }

    func restartEngine() async {
        await EngineAPI.shutdown()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await EngineLauncher.ensureRunning()
        await refreshStatus()
    }

    // MARK: Favorites

    func savePinAsFavorite(named name: String) {
        guard let pin else { return }
        let favorite = Favorite(id: UUID(), name: name.isEmpty ? pinLabel() : name,
                                lat: pin.latitude, lon: pin.longitude)
        favorites.append(favorite)
        FavoriteStore.save(favorites)
    }

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        FavoriteStore.save(favorites)
    }

    func pinLabel() -> String {
        if let pinName { return pinName }
        guard let pin else { return "Unnamed" }
        return String(format: "%.4f, %.4f", pin.latitude, pin.longitude)
    }
}
