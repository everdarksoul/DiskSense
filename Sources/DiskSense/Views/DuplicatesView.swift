import SwiftUI

private final class DuplicateViewState: ObservableObject { @Published var selected: Set<String> = [] }

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = DuplicateViewState()
    private var entries: [CatalogEntry] { model.duplicateGroups.flatMap(\.entries) }
    private var chosen: [CatalogEntry] { entries.filter { state.selected.contains($0.id) } }
    private var extraBytes: Int64 { model.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Same bytes. Different places.").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Exact copies, verified by SHA-256. Keep the one that belongs.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.duplicateIsScanning { Button("Stop checking") { model.stopDuplicateSearch() } }
                    else { Button(model.duplicateHasRun ? "Check again" : "Find duplicates") { model.findDuplicates() }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.snapshot == nil || model.isScanning || model.isCleaning) }
                }
                Text("Checks local files of 1 MB or larger in this scan. App bundles, managed photo/music libraries, Git, Trash, cloud placeholders and hard links are excluded. File contents are read only when you start this check; nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.duplicateHasRun {
                    HStack {
                        Label("\(model.duplicateGroups.count) groups", systemImage: "square.on.square")
                        Text("\(ByteFormat.string(extraBytes)) in extra copies").foregroundStyle(.teal)
                        Spacer()
                        Button("Select extra copies") { state.selected = Set(model.duplicateGroups.flatMap { $0.entries.dropFirst().map(\.id) }) }.disabled(entries.isEmpty)
                        Button("Clear") { state.selected = [] }.disabled(chosen.isEmpty)
                        Button("Review \(chosen.count) copies…") { model.reviewDuplicates(chosen) }.disabled(chosen.isEmpty || model.isCleaning || model.isScanning)
                    }.font(.caption).controlSize(.small)
                }
                if model.duplicateIsScanning {
                    HStack { ProgressView().controlSize(.small); Text(model.duplicateProgress).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
            }.padding(22)
            Divider()
            if let error = model.duplicateError {
                InsightEmptyView(symbol: "exclamationmark.triangle", title: "Could not finish checking", message: error)
            } else if model.duplicateHasRun && model.duplicateGroups.isEmpty {
                InsightEmptyView(symbol: "checkmark.seal", title: "One of a kind.", message: "No exact duplicate groups were verified among eligible files in this saved scan. Rescan first to include new files.")
            } else if model.duplicateGroups.isEmpty {
                InsightEmptyView(symbol: "square.on.square", title: model.duplicateIsScanning ? "Comparing local content…" : "Find the copies you forgot.", message: model.snapshot == nil ? "Finish a folder scan first, then start a duplicate check." : "We compare matching sizes first, then verify full file content. No copies are selected until you choose them.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.duplicateGroups) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack { Text("\(group.entries.count) identical copies").font(.callout.bold()); Text("· \(ByteFormat.string(group.bytesPerCopy)) each").font(.caption).foregroundStyle(.secondary); Spacer(); Text("SHA-256 verified").font(.caption2).foregroundStyle(.teal) }.padding(14)
                                ForEach(group.entries) { entry in
                                    Divider()
                                    HStack(spacing: 12) {
                                        Toggle("Select \(entry.path)", isOn: Binding(get: { state.selected.contains(entry.id) }, set: { value in if value { state.selected.insert(entry.id) } else { state.selected.remove(entry.id) } })).labelsHidden().toggleStyle(.checkbox)
                                        VStack(alignment: .leading, spacing: 4) { Text(entry.name).font(.callout.bold()); Text(entry.parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(entry.path) }
                                        Spacer()
                                        if !state.selected.contains(entry.id) { Text("Keep").font(.caption.bold()).foregroundStyle(.teal) }
                                        Text(ByteFormat.string(entry.bytes)).font(.caption.monospacedDigit())
                                        Button("Reveal") { model.reveal(entry.url) }.controlSize(.small)
                                    }.padding(14)
                                }
                            }.background(RoundedRectangle(cornerRadius: 13).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }.padding(22)
                }
            }
            HStack {
                Text("Keep at least one unchanged copy in every group. Files are checked again before review and Trash.")
                Spacer()
                if model.duplicateHasRun { Text("\(model.duplicateSkipped) skipped") }
            }.font(.caption2).foregroundStyle(.secondary).padding(16)
        }
        .onChange(of: model.duplicateID) { _ in state.selected = [] }
        .onChange(of: model.snapshot?.id) { _ in state.selected = [] }
    }
}
