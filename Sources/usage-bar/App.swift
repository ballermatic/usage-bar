import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var readings: [Reading] = []
    @Published var updated: Date?

    init() {
        Task { while true { await refresh(); try? await Task.sleep(for: .seconds(60)) } }
    }

    func refresh() async {
        async let c = readClaude()
        async let x = readCodex()
        async let o = readOpenCode()
        async let d = readDeepSeek()
        async let i = readDeepInfra()
        readings = await [c, x, o, d, i]
        updated = Date()
    }

    var title: String {
        if readings.isEmpty { return "…" }
        return readings.filter { $0.short != "DS" && $0.short != "DI" }.map { r in
            r.windows.first.map { "\(r.short) \(Int($0.percent.rounded()))" } ?? "\(r.short) –"
        }.joined(separator: " · ")
    }
}

@main
struct UsageBarApp: App {
    @StateObject private var store = Store()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }

    var body: some Scene {
        MenuBarExtra { PanelView(store: store) } label: { Text(store.title).monospacedDigit() }
            .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.readings) { r in
                VStack(alignment: .leading, spacing: 6) {
                    Text(r.name).font(.headline)
                    if let e = r.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                    if r.error == nil || !r.facts.isEmpty {
                        ForEach(r.windows) { WindowRow(w: $0) }
                        ForEach(r.facts, id: \.self) { Text($0).font(.caption) }
                        if let n = r.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Divider()
            HStack {
                Text(store.updated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Loading…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct WindowRow: View {
    let w: UsageWindow

    var tint: Color { w.percent >= 90 ? .red : w.percent >= 70 ? .orange : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(w.label).font(.caption)
                Spacer()
                Text("\(Int(w.percent.rounded()))%").font(.caption).monospacedDigit()
                if let d = w.resetsAt {
                    Text("resets \(d, format: .relative(presentation: .numeric))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(max(w.percent, 0), 100), total: 100).tint(tint)
        }
    }
}
