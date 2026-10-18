import SwiftUI

final class JunkState: ObservableObject { @Published var selected: Set<String> = [] }

struct JunkView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = JunkState()
    private var chosen: [JunkItem] { model.junk.filter { state.selected.contains($0.path) } }
    private var bytes: Int64 { chosen.reduce(0) { $0 + $1.bytes } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review cache and build data in your home folder").font(.title3.bold())
                        Text("\(ByteFormat.string(model.totalJunkBytes)) in \(model.junk.count) candidates").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review Selected…") {
                        model.reviewCleanup(chosen.map { CleanupCandidate(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes, reason: $0.note) })
                    }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty || model.isCleaning)
                }
                Text("Nothing is selected automatically. Caches can be rebuilt; removing build data may require downloads or recompilation. Close the related app first.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Select All") { state.selected = Set(model.junk.map(\.path)) }
                    Button("Clear") { state.selected = [] }
                    Spacer()
                    Text("\(chosen.count) selected · \(ByteFormat.string(bytes))").font(.caption.bold())
                }.controlSize(.small)
            }.padding(18)
            Divider()
            if model.junk.isEmpty {
                VStack(spacing: 12) {
                    if model.isScanning && !model.completedStages.contains("Cleanup") { ProgressView(); Text("Measuring cache candidates…") }
                    else { Image(systemName: "checkmark.circle").font(.largeTitle); Text("No cache candidates found in accessible folders.") }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                  LazyVStack(spacing: 12) {
                   ForEach(model.junk) { item in
                    Toggle(isOn: Binding(get: { state.selected.contains(item.path) }, set: { checked in
                        if checked { state.selected.insert(item.path) } else { state.selected.remove(item.path) }
                    })) {
                        HStack(spacing: 12) {
                            Image(systemName: item.kind.symbol).foregroundStyle(.orange).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.body.bold())
                                Text(item.note).font(.caption).foregroundStyle(.secondary)
                                Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.bytes)).font(.body.monospacedDigit()).frame(width: 100, alignment: .trailing)
                            Button { model.reveal(URL(fileURLWithPath: item.path)) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Reveal in Finder")
                        }.padding(.vertical, 6)
                    }.toggleStyle(.checkbox)
                   }
                  }.padding(18)
                }
            }
            HStack { Text("Moving to Trash is recoverable. Empty Trash in Finder to reclaim disk space."); Spacer(); Button("Open Trash") { model.openTrash() } }
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
    }
}
