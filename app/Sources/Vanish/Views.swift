import SwiftUI
import MapKit
import CoreLocation

// MARK: - Main layout

struct ContentView: View {
    @Bindable private var state = AppState.shared
    @State private var tab = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    Text("Teleport").tag(0)
                    Text("Route").tag(1)
                    Text("Joystick").tag(2)
                    Text("Favorites").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)

                switch tab {
                case 0: TeleportView()
                case 1: RouteView()
                case 2: JoystickView()
                default: FavoritesView()
                }

                Spacer(minLength: 0)
                StatusPanel()
            }
            .frame(width: 330)

            Divider()

            ZStack(alignment: .top) {
                VanishMapView(
                    pin: $state.pin,
                    fake: state.fakeCoord,
                    preview: state.routePreview,
                    follow: state.followFake
                ) { coordinate in
                    state.pin = coordinate
                    state.pinName = nil
                }

                if let hint = state.status?.hint {
                    HintBanner(text: hint)
                        .padding(.top, 10)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .task {
            await state.boot()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await state.refreshStatus()
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { state.errorMessage != nil },
                set: { if !$0 { state.errorMessage = nil } }
            )
        ) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }
}

// MARK: - Teleport

struct TeleportView: View {
    @Bindable private var state = AppState.shared
    @State private var favoriteName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchField { coordinate, name in
                state.pin = coordinate
                state.pinName = name
            }

            Button {
                if let pin = state.pin {
                    Task { await state.spoof(to: pin, name: state.pinName) }
                }
            } label: {
                Label(state.pinName ?? "Teleport to Pin", systemImage: "location.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.pin == nil)

            HStack {
                TextField("Favorite name", text: $favoriteName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    state.savePinAsFavorite(named: favoriteName)
                    favoriteName = ""
                } label: {
                    Image(systemName: "star")
                }
                .disabled(state.pin == nil)
                .help("Save pin to favorites")
            }

            Text("Tip: click anywhere on the map to drop a pin, or search above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - Search

struct SearchField: View {
    var onPick: (CLLocationCoordinate2D, String) -> Void

    @StateObject private var completer = SearchCompleter()
    @State private var query = ""
    @State private var directHits: [DirectHit] = []
    @State private var busy = false
    @State private var debounceTask: Task<Void, Never>?

    struct DirectHit: Identifiable {
        let id = UUID()
        let name: String
        let subtitle: String
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search a place or address…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await directSearch() } }
                    .onChange(of: query) { _, newValue in
                        completer.update(query: newValue)
                        debounceTask?.cancel()
                        directHits = []
                        let q = newValue.trimmingCharacters(in: .whitespaces)
                        guard q.count >= 3 else { return }
                        debounceTask = Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            guard !Task.isCancelled else { return }
                            await directSearch()
                        }
                    }
                if busy { ProgressView().controlSize(.small) }
            }

            ForEach(Array(completer.results.prefix(5).enumerated()), id: \.offset) { _, completion in
                Button {
                    query = completion.title
                    completer.results = []
                    busy = true
                    Task {
                        if let hit = await Self.resolve(completion) {
                            onPick(hit.coordinate, hit.name)
                        }
                        busy = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(completion.title).font(.callout)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }

            if !directHits.isEmpty {
                Text("Results")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            ForEach(directHits) { hit in
                Button {
                    query = hit.name
                    onPick(hit.coordinate, hit.name)
                    directHits = []
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hit.name).font(.callout)
                        if !hit.subtitle.isEmpty {
                            Text(hit.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
    }

    /// Direct Apple Maps search — the reliable fallback when the autocomplete
    /// service returns nothing (it also runs automatically while you type).
    private func directSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return }
        busy = true
        defer { busy = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let response = try? await MKLocalSearch(request: request).start() {
            directHits = response.mapItems.prefix(5).map { item in
                DirectHit(
                    name: item.name ?? item.placemark.title ?? "Unnamed",
                    subtitle: item.placemark.title ?? "",
                    coordinate: item.placemark.coordinate
                )
            }
        }
    }

    private static func resolve(_ completion: MKLocalSearchCompletion) async -> (coordinate: CLLocationCoordinate2D, name: String)? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return (item.placemark.coordinate, item.name ?? completion.title)
    }
}

final class SearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(query: String) {
        if query.isEmpty {
            results = []
        }
        completer.queryFragment = query
    }

    func completer(_ completer: MKLocalSearchCompleter, didUpdate results: [MKLocalSearchCompletion]) {
        DispatchQueue.main.async { self.results = results }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFail error: Error) {
        DispatchQueue.main.async { self.results = [] }
    }
}

// MARK: - Route

private enum RouteOrigin: String, CaseIterable, Identifiable {
    case spoofed = "Current spoofed position"
    case pin = "Map pin"
    var id: String { rawValue }
}

struct RouteView: View {
    @Bindable private var state = AppState.shared
    @State private var destination: CLLocationCoordinate2D?
    @State private var destinationName: String?
    @State private var origin: RouteOrigin = .spoofed
    @State private var mode: TravelMode = .drive

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Origin").font(.callout).bold()
            Picker("Origin", selection: $origin) {
                ForEach(RouteOrigin.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()

            Text("Destination").font(.callout).bold()
            SearchField { coordinate, name in
                destination = coordinate
                destinationName = name
            }
            if let destination {
                Text(destinationName ?? String(format: "%.4f, %.4f", destination.latitude, destination.longitude))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $mode) {
                ForEach(TravelMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if state.isRouteRunning, let progress = state.status?.route {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(progress.index), total: Double(max(progress.total, 1)))
                    Text("Waypoint \(progress.index) of \(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await state.stop() }
                    } label: {
                        Label("Stop Route", systemImage: "stop.fill")
                    }
                }
            } else {
                Button {
                    Task { await start() }
                } label: {
                    Label("Start Route", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(destination == nil)
            }

            if state.routePreview.count > 1 {
                Text("\(state.routePreview.count) waypoints planned (shown on map)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
    }

    private func start() async {
        guard let destination else { return }
        let source: CLLocationCoordinate2D?
        switch origin {
        case .spoofed: source = state.fakeCoord ?? state.pin
        case .pin: source = state.pin
        }
        await state.startRoute(to: destination, from: source, mode: mode)
    }
}

// MARK: - Joystick

struct JoystickView: View {
    @Bindable private var state = AppState.shared
    @State private var step: Double = 200
    private let steps: [Double] = [50, 200, 1000, 5000]

    var body: some View {
        VStack(spacing: 14) {
            Picker("Step", selection: $step) {
                ForEach(steps, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    padButton("arrow.up.left", dx: -step * 0.707, dy: step * 0.707)
                    padButton("arrow.up", dx: 0, dy: step)
                    padButton("arrow.up.right", dx: step * 0.707, dy: step * 0.707)
                }
                HStack(spacing: 6) {
                    padButton("arrow.left", dx: -step, dy: 0)
                    padButton("", dx: 0, dy: 0, inert: true)
                    padButton("arrow.right", dx: step, dy: 0)
                }
                HStack(spacing: 6) {
                    padButton("arrow.down.left", dx: -step * 0.707, dy: -step * 0.707)
                    padButton("arrow.down", dx: 0, dy: -step)
                    padButton("arrow.down.right", dx: step * 0.707, dy: -step * 0.707)
                }
            }
            .frame(maxWidth: .infinity)

            Text("Nudges the spoofed position by ~\(label(step)). Teleport first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    private func label(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.0f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    @ViewBuilder
    private func padButton(_ symbol: String, dx: Double, dy: Double, inert: Bool = false) -> some View {
        if inert {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(.tertiary)
                .frame(width: 44, height: 36)
        } else {
            Button {
                Task { await state.nudge(dxMeters: dx, dyMeters: dy) }
            } label: {
                Image(systemName: symbol)
                    .frame(width: 44, height: 36)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Favorites

struct FavoritesView: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        List {
            if state.favorites.isEmpty {
                Text("No favorites yet — drop a pin on the map and star it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.favorites) { favorite in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(favorite.name).font(.callout)
                        Text(String(format: "%.4f, %.4f", favorite.lat, favorite.lon))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await state.spoof(to: favorite.coordinate, name: favorite.name) }
                    } label: {
                        Image(systemName: "location.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Teleport here")
                    Button {
                        state.removeFavorite(favorite)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove")
                }
            }
        }
        .listStyle(.inset)
        .padding(.horizontal, 4)
    }
}

// MARK: - Status panel & hint

struct StatusPanel: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.engineOnline ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text(state.statusText)
                    .font(.callout)
                    .lineLimit(1)
                if state.status?.mode == "mock" {
                    Text("MOCK")
                        .font(.caption2)
                        .bold()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                if state.isSpoofing {
                    Button {
                        Task { await state.stop() }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop spoofing")
                }
                Button {
                    Task { await state.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan for iPhone")
            }

            if let session = state.status?.session {
                Text(String(format: "Fake position: %.5f, %.5f · layer: %@",
                            session.lat, session.lon, session.layer ?? "-"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if state.status?.session == nil, let stopped = state.lastStoppedAt,
               Date().timeIntervalSince(stopped) < 120 {
                Text("Real GPS restored — the simulated feed is cut instantly, and your phone shows its true location on its next fix. Open Apple Maps on the iPhone for an instant fix; Find My can lag a few minutes when stationary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if let remote = state.status?.remote {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                    Text("\(remote.url) · PIN \(remote.pin)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Toggle("Control from iPhone over Wi-Fi", isOn: Binding(
                get: { state.lanMode },
                set: { state.setLanMode($0) }
            ))
            .font(.caption)

            Toggle("Follow spoofed position on map", isOn: $state.followFake)
                .font(.caption)
        }
        .padding(10)
    }
}

struct HintBanner: View {
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 60)
    }
}
