import AppKit
import SwiftUI

final class AppsState: ObservableObject {
    @Published var search = ""
    @Published var selectedID: String?
}
private final class ConnectionsState: ObservableObject {
    @Published var selected: Set<String> = []
    @Published var running = false
}

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = AppsState()
    private var filtered: [AppEntry] {
        model.apps.filter { state.search.isEmpty || $0.name.localizedCaseInsensitiveContains(state.search) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(state.search) }
    }
    private var selected: AppEntry? { filtered.first { $0.id == state.selectedID } ?? filtered.first }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Applications").font(.title2.bold())
                TextField("Find an app…", text: $state.search).textFieldStyle(.roundedBorder)
                Text("\(filtered.count) apps · \(ByteFormat.string(filtered.reduce(0) { $0 + $1.allocatedBytes }))").font(.caption).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { app in
                            Button { state.selectedID = app.id } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path)).resizable().frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(app.name).font(.callout.bold()).lineLimit(1)
                                        Text("\(ByteFormat.string(app.allocatedBytes)) · \(app.relatedFiles.count) connected").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).background(RoundedRectangle(cornerRadius: 10).fill(selected?.id == app.id ? Color.teal.opacity(0.14) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(18).frame(width: 245)
            Divider()
            if let app = selected { AppConnectionsView(app: app).id(app.id) }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "app.dashed").font(.largeTitle)
                    Text(model.isScanning ? "Measuring installed apps…" : "No matching applications")
                    Text("Refresh Apps & Cleanup to build the inventory.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AppConnectionsView: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry
    @StateObject private var state = ConnectionsState()
    private var selectedBytes: Int64 {
        (state.selected.contains(app.appURL.path) ? app.allocatedBytes : 0) + app.relatedFiles.filter { state.selected.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }
    private var selectable: Set<String> { Set(app.relatedFiles.filter { !$0.managedService }.map(\.path)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.appURL.path)).resizable().frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).font(.title.bold())
                        Text([app.bundleIdentifier, app.version].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Reveal app") { model.reveal(app.appURL) }
                }
                Text("Your apps moved out. Their crumbs didn’t.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Label(state.running ? "Running" : "Not running", systemImage: state.running ? "circle.fill" : "checkmark.circle").font(.caption).foregroundStyle(state.running ? .orange : .teal)
                    if state.running { Button("Ask app to quit") { model.requestQuit(app) }.controlSize(.small) }
                    Spacer()
                    Text("\(app.relatedFiles.count) possible connections · \(ByteFormat.string(app.relatedBytes))").font(.caption.bold())
                }
                Text("Inspect and reveal anything without uninstalling. Matching does not prove exclusive ownership. Unrelated apps may stay open; quit this app before removing its files.").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("APPLICATION BUNDLE").font(.caption2.bold()).foregroundStyle(.secondary)
                        connectionRow(path: app.appURL.path, bytes: app.allocatedBytes, title: app.name, note: "Select only if you want to uninstall the app", enabled: !app.appURL.path.hasPrefix("/System/") && app.appURL.path != Bundle.main.bundleURL.path)
                    }
                    ForEach(RelatedFile.Category.allCases, id: \.rawValue) { category in
                        let files = app.relatedFiles.filter { $0.category == category }
                        if !files.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("\(category.rawValue.uppercased()) · \(files.count)", systemImage: category.symbol).font(.caption2.bold()).foregroundStyle(.secondary)
                                ForEach(files) { file in
                                    connectionRow(path: file.path, bytes: file.bytes, title: URL(fileURLWithPath: file.path).lastPathComponent, note: file.caution, enabled: !file.managedService)
                                }
                            }
                        }
                    }
                    if app.relatedFiles.isEmpty { Text("No matching connected files in accessible locations. A missing result does not prove there are no leftovers.").font(.callout).foregroundStyle(.secondary) }
                    Label("Admin-protected items: reveal in Finder to use macOS authentication. This beta has no privileged helper and does not bypass permissions or SIP.", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(22)
            }
            Divider()
            HStack {
                Menu("Select…") {
                    Button("Related files only") { state.selected = selectable }
                    Button("App bundle only") { state.selected = [app.appURL.path] }.disabled(app.appURL.path.hasPrefix("/System/") || app.appURL.path == Bundle.main.bundleURL.path)
                    Button("Clear selection") { state.selected = [] }
                }.fixedSize()
                Text("\(state.selected.count) selected · \(ByteFormat.string(selectedBytes))").font(.caption)
                Spacer()
                Button("Review removal…") { model.reviewConnections(app: app, paths: state.selected) }.buttonStyle(.borderedProminent).tint(.teal).disabled(state.selected.isEmpty || state.running || model.isCleaning)
            }.padding(16)
        }
        .onAppear { state.running = model.isRunning(app) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in state.running = model.isRunning(app) }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in state.running = model.isRunning(app) }
    }
    private func connectionRow(path: String, bytes: Int64, title: String, note: String, enabled: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(path)", isOn: Binding(get: { state.selected.contains(path) }, set: { value in
                if value { state.selected.insert(path) } else { state.selected.remove(path) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(!enabled)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.bold()).lineLimit(1)
                Text(path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Text(note).font(.caption2).foregroundStyle(enabled ? Color.secondary : .orange)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Text(ByteFormat.string(bytes)).font(.caption.monospacedDigit())
                Button("Reveal") { model.reveal(URL(fileURLWithPath: path)) }.controlSize(.small)
            }
        }.padding(13).background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
