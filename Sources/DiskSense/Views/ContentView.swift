import SwiftUI

@main
struct DiskSenseApp: App {
    @StateObject private var model = AppModel.live()
    var body: some Scene {
        WindowGroup("LintGoblin", id: "main") {
            ContentView().environmentObject(model).frame(minWidth: 1120, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut("o")
            }
            CommandMenu("Storage") {
                Button("Refresh Scan") { model.refreshFolder() }.keyboardShortcut("r").disabled(model.isScanning || model.isCleaning || model.isBootstrapping)
                Button("Stop Scan") { model.cancelScan() }.keyboardShortcut(".").disabled(!model.isScanning)
                Divider()
                Button("Find Files") { model.selection = .search }.keyboardShortcut("f")
                Button("Space Map") { model.selection = .spaceMap }.keyboardShortcut("2")
                Button("Quick Switcher…") { model.showingCommandPalette = true }.keyboardShortcut("k")
                Button("Export Report…") { model.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.snapshot == nil)
            }
        }
        MenuBarExtra("LintGoblin", systemImage: "chart.pie.fill") {
            DiskPulsePanel().environmentObject(model)
        }.menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var shell = ShellState()
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button { shell.showingPulse.toggle() } label: { DiskPulseMark(size: 42, animated: model.isScanning) }
                        .buttonStyle(.plain).help("Meet the Goblin · storage at a glance").accessibilityLabel("Open Goblin storage panel")
                        .popover(isPresented: $shell.showingPulse, arrowEdge: .leading) { DiskPulsePanel().environmentObject(model) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LintGoblin").font(.title3.bold())
                        Text("ROOM TO BREATHE").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary)
                    }
                }.padding(18)
                List(selection: $model.selection) {
                    Section("EXPLORE") { sidebarRows([.overview, .spaceMap, .search, .changes]) }
                    Section("CLEAN") { sidebarRows([.plan, .duplicates, .apps, .junk]) }
                    Section("HISTORY") { sidebarRows([.history]) }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 10) {
                    Text("ANALYZE").font(.caption2.bold()).foregroundStyle(.secondary)
                    Button { model.selectRoot(FileManager.default.homeDirectoryForCurrentUser) } label: { Label("Home folder", systemImage: "house") }
                    Button { model.selectRoot(URL(fileURLWithPath: "/System/Volumes/Data")) } label: { Label("Startup disk", systemImage: "internaldrive") }
                    Button { model.chooseFolder() } label: { Label("Choose folder or volume…", systemImage: "folder.badge.plus") }
                }.buttonStyle(.plain).padding(18).disabled(model.isCleaning)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(model.overview.volumeName).font(.caption.bold()).lineLimit(1); Spacer(); Image(systemName: "internaldrive") }
                    ProgressView(value: usedFraction).tint(.blue)
                    Text("\(ByteFormat.string(model.overview.freeSpace)) available of \(ByteFormat.string(model.overview.totalCapacity))")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16)
                if model.overview.needsFullDiskAccess {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Some folders are protected", systemImage: "lock").font(.caption.bold())
                        Text("Accessible data still scans. If the switch is already on, turn it off and on for this build, then reopen LintGoblin.")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Settings") { FullDiskAccess.openPrivacyPane() }
                            Button("Recheck") { model.refreshDiskAccess() }
                        }.controlSize(.small)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.1))
                }
            }.navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                toolbar
                if let notice = model.notice {
                    HStack {
                        Image(systemName: "info.circle").foregroundStyle(.blue)
                        Text(notice).font(.caption)
                        Spacer()
                        if notice.contains("Trash") { Button("Open Trash") { model.openTrash() }.controlSize(.small) }
                        Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(.blue.opacity(0.07))
                }
                if model.isBootstrapping {
                    HStack { ProgressView().controlSize(.small); Text("Opening saved scans and optimizing local storage…").font(.caption); Spacer() }.padding(12)
                }
                if [.apps, .junk, .plan].contains(model.selection) {
                    HStack {
                        Text(model.inventoryDate.map { "Inventory measured " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Inventory has not been measured yet").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh apps & cleanup") { model.refreshInventories() }.controlSize(.small).disabled(model.isScanning || model.isCleaning || model.isBootstrapping)
                    }.padding(.horizontal, 22).padding(.vertical, 8)
                }
                if model.snapshot?.indexTruncated == true {
                    Label("Index budget reached. Folder totals are measured, but search and duplicate results cover only indexed files. Choose a smaller folder for full coverage.", systemImage: "info.circle").font(.caption).foregroundStyle(.orange).padding(12)
                }
                if let warning = model.persistenceWarning {
                    Label("Saved results: " + warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).padding(10)
                }
                Group {
                    switch model.selection {
                    case .overview: OverviewView()
                    case .spaceMap: SpaceMapView()
                    case .search: FindFilesView()
                    case .changes: ChangesView()
                    case .history: ActivityView()
                    case .duplicates: DuplicatesView()
                    case .plan: CleanupPlanView()
                    case .apps: AppsView()
                    case .junk: JunkView()
                    case .browser: BrowserView()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isScanning { scanStatus }
            }
        }
        .onAppear { model.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshDiskAccess() }
        .confirmationDialog("Clear saved scan indexes?", isPresented: $model.showingClearScanConfirmation) {
            Button("Clear Saved Scans", role: .destructive) { model.clearSavedScans() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes LintGoblin’s cached file indexes. Your files and cleanup history are kept.") }
        .sheet(isPresented: $model.showingCleanup) { CleanupReviewView().environmentObject(model) }
        .sheet(isPresented: $model.showingCommandPalette) { CommandPaletteView().environmentObject(model) }
        .alert("LintGoblin", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func sidebarRows(_ tabs: [SidebarTab]) -> some View {
        ForEach(tabs) { tab in Label(tab.rawValue, systemImage: tab.symbol).tag(tab) }
    }

    private var usedFraction: Double {
        guard model.overview.totalCapacity > 0 else { return 0 }
        return min(1, max(0, Double(model.overview.usedBytes) / Double(model.overview.totalCapacity)))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selection.rawValue).font(.title2.bold())
                Text(model.scanRoot.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let snapshot = model.snapshot {
                VStack(alignment: .trailing, spacing: 3) {
                    Label(model.showingSavedScan ? "Saved scan" : "Indexed locally", systemImage: model.showingSavedScan ? "clock" : "checkmark.seal")
                        .font(.caption.bold()).foregroundStyle(.teal)
                    Text(snapshot.finished.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Menu {
                if model.savedSnapshots.isEmpty { Text("No saved scans yet") }
                ForEach(model.savedSnapshots.prefix(12)) { snapshot in
                    Button("\(URL(fileURLWithPath: snapshot.root).lastPathComponent) · \(snapshot.finished.formatted(date: .abbreviated, time: .shortened))") { model.openSnapshot(snapshot) }
                }
                Divider()
                Button("Export Report…") { model.exportReport() }.disabled(model.snapshot == nil)
                Divider()
                Text("Local index: \(ByteFormat.string(model.localIndexBytes))")
                if let store = model.store { Button("Reveal Local Data") { model.reveal(store.directory) } }
                Button("Clear Saved Scans…") { model.showingClearScanConfirmation = true }.disabled(model.isScanning || model.isCleaning || model.store == nil)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 25).help("Saved scans and export")
            if model.isCleaning { ProgressView().controlSize(.small); Text(model.cleaningLabel).font(.caption) }
            if model.isScanning {
                Button("Stop Scan") { model.cancelScan() }
            } else {
                Button { model.refreshFolder() } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(model.isCleaning || model.isBootstrapping)
            }
        }.padding(.horizontal, 22).padding(.vertical, 16).background(.bar)
    }

    private var scanStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Scanning").font(.caption.bold())
                if model.scannedItemCount > 0 { Text("\(model.scannedItemCount.formatted()) entries indexed").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                ForEach(["Folders", "Apps", "Cleanup"].filter { model.stageMessages[$0] != nil }, id: \.self) { stage in
                    Label(stage, systemImage: model.completedStages.contains(stage) ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption2).foregroundStyle(model.completedStages.contains(stage) ? .teal : .secondary)
                }
            }
            Text(model.stageMessages["Folders"] ?? model.stageMessages["Apps"] ?? "Finishing…").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }.padding(.horizontal, 18).padding(.vertical, 10).background(.thinMaterial)
    }

}

private final class ShellState: ObservableObject { @Published var showingPulse = false }

struct CleanupReviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.cleanupDisposition == .trash ? "Review before moving to Trash" : "Review permanent deletion", systemImage: model.cleanupDisposition == .trash ? "trash" : "exclamationmark.triangle").font(.title2.bold())
            Text("Only checked items will be removed. Sizes reflect the last measurement. Support files may contain settings and personal data. Quit the associated app first.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
             LazyVStack(alignment: .leading, spacing: 14) {
              ForEach(model.cleanupCandidates) { item in
                Toggle(isOn: Binding(get: { model.cleanupSelection.contains(item.id) }, set: { checked in
                    if checked { model.cleanupSelection.insert(item.id) } else { model.cleanupSelection.remove(item.id) }
                })) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent).font(.body.bold())
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            Text(item.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(ByteFormat.string(item.bytes)).monospacedDigit()
                        Button { model.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }.help("Reveal in Finder")
                    }
                }.toggleStyle(.checkbox)
              }
             }.padding(12)
            }.frame(minHeight: 220)
            Picker("Removal method", selection: $model.cleanupDisposition) {
                Text("Move to Trash").tag(CleanupDisposition.trash)
                Text("Delete permanently").tag(CleanupDisposition.permanent)
            }.pickerStyle(.segmented)
            if model.cleanupDisposition == .permanent {
                Text("Permanent deletion bypasses Trash and cannot be undone here. Type DELETE to enable it. Files may also exist in backups or APFS snapshots.").font(.caption).foregroundStyle(.red)
                TextField("Type DELETE", text: $model.permanentConfirmation).textFieldStyle(.roundedBorder)
            } else { Text("Items remain recoverable in Trash. Empty Trash in Finder to reclaim space.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("\(model.cleanupSelection.count) selected · \(ByteFormat.string(model.selectedCleanupBytes))").font(.callout.bold())
                Spacer()
                Button("Cancel") { model.showingCleanup = false }.keyboardShortcut(.cancelAction)
                Button(model.cleanupDisposition == .trash ? "Move to Trash" : "Delete Permanently") { model.confirmCleanup() }.buttonStyle(.borderedProminent).tint(model.cleanupDisposition == .trash ? .accentColor : .red).disabled(model.cleanupSelection.isEmpty || (model.cleanupDisposition == .permanent && model.permanentConfirmation != "DELETE"))
            }
        }.padding(24).frame(width: 720, height: 620)
        .onChange(of: model.cleanupSelection) { _ in model.permanentConfirmation = "" }
        .onChange(of: model.cleanupDisposition) { _ in model.permanentConfirmation = "" }
    }
}
