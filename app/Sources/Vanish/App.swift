import SwiftUI
import AppKit

@main
struct VanishApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1080, height: 680)

        MenuBarExtra("Vanish", systemImage: "location.slash.fill") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Lightweight menu-bar panel: status, favorite teleports, stop.
struct MenuBarContent: View {
    @Bindable private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.engineOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.callout)
            }
            .padding(.horizontal, 4)

            if let s = state.status?.session {
                Text(String(format: "%.5f, %.5f", s.lat, s.lon))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            Divider()

            if !state.favorites.isEmpty {
                Text("Teleport to…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(state.favorites.prefix(6)) { fav in
                    Button {
                        Task { await state.spoof(to: fav.coordinate, name: fav.name) }
                    } label: {
                        Label(fav.name, systemImage: "location.fill")
                    }
                }
                Divider()
            }

            Button {
                Task { await state.stop() }
            } label: {
                Label("Stop Spoofing", systemImage: "stop.circle")
            }
            .disabled(state.status?.session == nil)

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Vanish", systemImage: "macwindow")
            }

            Divider()

            Button("Quit & Stop Spoofing") {
                Task {
                    await state.stop()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    NSApp.terminate(nil)
                }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 240)
        .task { await state.refreshStatus() }
    }
}

