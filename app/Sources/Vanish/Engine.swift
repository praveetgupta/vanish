import Foundation
import CoreLocation

// MARK: - Models

struct DeviceInfo: Codable {
    var udid: String
    var name: String
    var ios: String
    var connection: String
}

struct SessionInfo: Codable {
    var lat: Double
    var lon: Double
    var kind: String?
    var layer: String?
}

struct RouteProgress: Codable {
    var running: Bool
    var index: Int
    var total: Int
}

struct RemoteInfo: Codable {
    var url: String
    var pin: String
}

struct EngineStatus: Codable {
    var engine: String
    var mode: String
    var device: DeviceInfo?
    var session: SessionInfo?
    var route: RouteProgress?
    var remote: RemoteInfo?
    var hint: String?
}

struct RoutePoint: Codable {
    var lat: Double
    var lon: Double
    var delayMs: Double

    enum CodingKeys: String, CodingKey {
        case lat, lon
        case delayMs = "delay_ms"
    }
}

struct ErrorResponse: Codable {
    var error: String
}

enum EngineError: LocalizedError {
    case server(String)
    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}

// MARK: - HTTP client

enum EngineAPI {
    static let baseURL = URL(string: "http://127.0.0.1:8799")!

    static func status() async throws -> EngineStatus {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.server("engine returned an error")
        }
        return try JSONDecoder().decode(EngineStatus.self, from: data)
    }

    static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 45) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.server("no response from engine")
        }
        guard http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "engine error \(http.statusCode)"
            throw EngineError.server(message)
        }
    }

    static func spoof(lat: Double, lon: Double) async throws {
        try await post("api/spoof", ["lat": lat, "lon": lon])
    }

    static func move(lat: Double, lon: Double) async throws {
        try await post("api/move", ["lat": lat, "lon": lon])
    }

    static func route(points: [RoutePoint], loop: Bool = false) async throws {
        let encoded: [[String: Any]] = points.map { ["lat": $0.lat, "lon": $0.lon, "delay_ms": $0.delayMs] }
        try await post("api/route", ["points": encoded, "loop": loop], timeout: 120)
    }

    static func stop() async throws {
        try await post("api/stop", [:])
    }

    static func refresh() async throws {
        try await post("api/refresh", [:], timeout: 60)
    }

    /// Ask the engine to stop spoofing and exit. Best-effort: the engine may
    /// kill itself before the response arrives.
    static func shutdown() async {
        _ = try? await post("api/shutdown", [:], timeout: 10)
    }
}

// MARK: - Engine launcher (spawns the Python daemon if it isn't running)

enum EngineLauncher {
    /// Where to look for `engine/daemon.py`, most specific first:
    ///
    /// 1. `defaults write local.vanish.app engineDir <path>` — manual override
    /// 2. `VANISH_ENGINE_DIR` in the environment — handy for `swift run`
    /// 3. `Vanish.app/Contents/Resources/engine` — the shipped bundle
    /// 4. an `engine/` directory beside any ancestor of the executable — a dev
    ///    checkout, where the binary sits in `app/.build/release/Vanish`
    static var engineDir: String? {
        var candidates: [String] = []

        if let override = UserDefaults.standard.string(forKey: "engineDir") {
            candidates.append(override)
        }
        if let fromEnv = ProcessInfo.processInfo.environment["VANISH_ENGINE_DIR"] {
            candidates.append(fromEnv)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("engine").path {
            candidates.append(bundled)
        }

        // Walk up from the executable: .../vanish/app/.build/release/Vanish
        // reaches .../vanish/engine in four hops.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("engine").path)
            dir = dir.deletingLastPathComponent()
        }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0 + "/daemon.py")
        }
    }

    static func isOnline() async -> Bool {
        (try? await EngineAPI.status()) != nil
    }

    @discardableResult
    static func ensureRunning() async -> Bool {
        if await isOnline() { return true }

        guard let engineDir else { return false }
        let python = engineDir + "/venv/bin/python"
        let script = engineDir + "/daemon.py"
        guard FileManager.default.fileExists(atPath: python) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + (UserDefaults.standard.bool(forKey: "lanMode") ? ["--lan"] : [])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }

        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await isOnline() { return true }
        }
        return false
    }
}

// MARK: - Favorites

struct Favorite: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

enum FavoriteStore {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vanish", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("favorites.json")
    }

    static func load() -> [Favorite] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Favorite].self, from: data)) ?? []
    }

    static func save(_ favorites: [Favorite]) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
