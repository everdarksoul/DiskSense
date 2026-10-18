import AppKit
import SwiftUI

/// The live counterpart of the app icon. It respects Reduce Motion and only
/// requests animation frames while a visible host asks for movement.
struct DiskPulseMark: View {
    let size: CGFloat
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !animated)) { context in
            let time = reduceMotion || !animated ? 0 : context.date.timeIntervalSinceReferenceDate
            let angle = time.truncatingRemainder(dividingBy: 18) * 20
            let bob = sin(time * 1.8) * size * 0.025
            ZStack {
                Circle().fill(.teal.opacity(0.09)).frame(width: size * 0.98, height: size * 0.98)
                ZStack {
                    Circle().trim(from: 0.015, to: 0.43).stroke(Color(red: 0.38, green: 0.86, blue: 0.76), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    Circle().trim(from: 0.47, to: 0.72).stroke(Color(red: 0.48, green: 0.54, blue: 0.96), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    Circle().trim(from: 0.76, to: 0.975).stroke(Color(red: 0.94, green: 0.66, blue: 0.48), style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                }.frame(width: size * 0.75, height: size * 0.75).rotationEffect(.degrees(angle - 90))
                Circle().fill(Color(red: 0.06, green: 0.24, blue: 0.28)).frame(width: size * 0.49, height: size * 0.49)
                HStack(spacing: size * 0.08) {
                    Capsule().fill(.white.opacity(0.95)).frame(width: size * 0.045, height: size * 0.095)
                    Capsule().fill(.white.opacity(0.95)).frame(width: size * 0.045, height: size * 0.095)
                }.offset(y: bob)
                Circle().fill(.teal).frame(width: size * 0.035, height: size * 0.035).offset(x: size * 0.43, y: -size * 0.3 + bob)
                Circle().fill(.indigo.opacity(0.65)).frame(width: size * 0.025, height: size * 0.025).offset(x: -size * 0.43, y: size * 0.28 - bob)
            }.frame(width: size, height: size)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct DiskPulsePanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    private var fraction: Double {
        model.overview.totalCapacity > 0 ? min(1, max(0, Double(model.overview.usedBytes) / Double(model.overview.totalCapacity))) : 0
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                DiskPulseMark(size: 78)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Meet Orbit.").font(.title2.bold())
                    Text(model.isScanning ? "Your storage scout is exploring." : "A little perspective. A lot more space.").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ByteFormat.string(model.overview.freeSpace)).font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("available").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(LinearGradient(colors: [.teal, .indigo], startPoint: .leading, endPoint: .trailing)).frame(width: geo.size.width * fraction)
                    }
                }.frame(height: 7)
                Text("\(model.overview.volumeName) · \(ByteFormat.string(model.overview.totalCapacity)) total").font(.caption2).foregroundStyle(.secondary)
            }
            if model.isScanning {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(model.scannedItemCount.formatted()) entries indexed").font(.caption.bold()); Spacer(); Button("Stop") { model.cancelScan() } }
                Text(model.stageMessages["Folders"] ?? "Finishing inventories…").font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            } else if let snapshot = model.snapshot {
                Label("Saved \(snapshot.finished.formatted(date: .abbreviated, time: .shortened)) · \(model.rootName)", systemImage: "clock").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button { open(.spaceMap) } label: { Label("Space Map", systemImage: "rectangle.3.group.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).tint(.teal)
                Button { open(.plan) } label: { Label("Make room", systemImage: "sparkles").frame(maxWidth: .infinity) }
            }
            HStack {
                Button("Open DiskSense") { open(.overview) }
                Spacer()
                Button { model.runFullScan() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh selected location").disabled(model.isScanning || model.isCleaning)
            }.font(.caption)
        }.padding(22).frame(width: 340)
        .background(LinearGradient(colors: [.teal.opacity(0.07), .clear, .indigo.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .onAppear { model.refreshVolumeCapacity() }
    }
    private func open(_ tab: SidebarTab) {
        model.selection = tab
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        dismiss()
    }
}

struct CommandPaletteView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = CommandPaletteState()
    private var tabs: [SidebarTab] { SidebarTab.allCases.filter { state.query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(state.query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Image(systemName: "command").foregroundStyle(.teal); Text("Go somewhere useful.").font(.title2.bold()); Spacer(); Button("Done") { model.showingCommandPalette = false }.keyboardShortcut(.cancelAction) }
            TextField("Search tools…", text: $state.query).textFieldStyle(.roundedBorder).onSubmit { if let first = tabs.first { go(first) } }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Button { go(tab) } label: {
                            HStack(spacing: 12) { Image(systemName: tab.symbol).foregroundStyle(.teal).frame(width: 24); Text(tab.rawValue); Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary) }.padding(13).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text("Command-K from anywhere · Return opens the first match").font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 530, height: 480)
    }
    private func go(_ tab: SidebarTab) { model.selection = tab; model.showingCommandPalette = false }
}
private final class CommandPaletteState: ObservableObject { @Published var query = "" }
