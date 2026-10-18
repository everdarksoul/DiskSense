import SwiftUI

struct ChangesView: View {
    @EnvironmentObject var model: AppModel
    private var net: Int64 { model.changes.reduce(0) { $0 + $1.delta } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("What changed since last time?").font(.title2.bold())
            if let current = model.snapshot, let previous = model.previousSnapshot {
                Text("\(previous.finished.formatted(date: .abbreviated, time: .shortened)) → \(current.finished.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    metric("Grew", count: model.changes.filter { $0.delta > 0 }.count, color: .orange)
                    metric("Shrank or removed", count: model.changes.filter { $0.delta < 0 }.count, color: .teal)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(net > 0 ? "+" : (net < 0 ? "−" : ""))\(ByteFormat.string(abs(net)))").font(.title.bold())
                        Text("Net change in measured allocation").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                if current.unreadable > 0 || previous.unreadable > 0 {
                    Label("Partial coverage: \(previous.unreadable) unreadable before, \(current.unreadable) now. Permission changes can look like growth or removal.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.changes.isEmpty {
                    InsightEmptyView(symbol: "equal.circle", title: "No measured changes", message: "The top-level items have the same allocated sizes in both scans.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.changes) { change in
                                HStack(spacing: 14) {
                                    Image(systemName: change.delta > 0 ? "arrow.up.right" : "arrow.down.right").font(.title3).foregroundStyle(change.delta > 0 ? .orange : .teal)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: change.path).lastPathComponent).font(.body.bold())
                                        Text("\(ByteFormat.string(change.before)) → \(ByteFormat.string(change.after))\(change.before == 0 ? " · Added or newly accessible" : (change.after == 0 ? " · Removed or no longer accessible" : ""))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(change.delta > 0 ? "+" : "−")\(ByteFormat.string(abs(change.delta)))").font(.body.monospacedDigit()).foregroundStyle(change.delta > 0 ? .orange : .teal)
                                    Button("Browse") { model.browse(URL(fileURLWithPath: current.root)) }.controlSize(.small)
                                }.padding(.vertical, 14)
                                Divider()
                            }
                        }
                    }
                }
                Text("Compares immediate items in the same scanned location. Bytes moved to Trash may remain on the volume until Trash is emptied.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                InsightEmptyView(symbol: "arrow.up.arrow.down.circle", title: "Two scans tell a better story", message: "Scan this location again to see what grew, shrank, appeared or disappeared. The last two completed scans are kept automatically.")
                HStack { Spacer(); Button("Scan again") { model.runFullScan() }.buttonStyle(.borderedProminent).disabled(model.isScanning); Spacer() }
            }
        }.padding(22)
    }
    private func metric(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text("\(count)").font(.title.bold()).foregroundStyle(color); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}
