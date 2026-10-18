import SwiftUI

final class BrowserState: ObservableObject { @Published var search = "" }

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = BrowserState()
    private var items: [ScanItem] {
        model.browserItems.filter { state.search.isEmpty || $0.name.localizedCaseInsensitiveContains(state.search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            ExplorerNavigationBar(location: model.browserURL).padding(.horizontal, 14)
            HStack {
                TextField("Filter this folder…", text: $state.search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Text("\(items.count) items · \(ByteFormat.string(model.browserTotal)) on disk").font(.caption).foregroundStyle(.secondary)
                Button("Review Selected…") {
                    model.reviewCleanup(model.browserItems.filter { model.browserSelection.contains($0.id) }.map {
                        CleanupCandidate(url: $0.url, bytes: $0.allocatedBytes, reason: "Selected in File Browser")
                    })
                }.disabled(model.browserSelection.isEmpty || model.isCleaning)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if items.isEmpty && !model.browserIsScanning && !(model.isScanning && model.browserURL == model.scanRoot) {
                VStack(spacing: 10) {
                    Image(systemName: model.browserUnreadable > 0 ? "lock.folder" : "folder").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.browserUnreadable > 0 ? "This folder could not be read." : "No matching items in this folder.")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                 LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            Toggle("Select \(item.name)", isOn: Binding(get: { model.browserSelection.contains(item.id) }, set: { checked in
                                if checked { model.browserSelection.insert(item.id) } else { model.browserSelection.remove(item.id) }
                            })).labelsHidden().toggleStyle(.checkbox)
                            Image(systemName: item.isPackage ? "shippingbox" : (item.isDirectory ? "folder.fill" : "doc"))
                                .foregroundStyle(item.isDirectory ? .blue : .secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.body).lineLimit(1)
                                if item.isUnreadable { Text("Partial size · some files could not be read").font(.caption2).foregroundStyle(.orange) }
                                GeometryReader { geo in
                                    Capsule().fill(Color.blue.opacity(0.45)).frame(width: max(2, geo.size.width * fraction(item)), height: 4)
                                }.frame(width: 210, height: 4)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.allocatedBytes)).font(.body.monospacedDigit()).frame(width: 100, alignment: .trailing)
                            Button { model.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Reveal in Finder")
                            if item.isDirectory {
                                Button { state.search = ""; model.browse(item.url) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Open folder")
                            }
                        }.padding(.vertical, 10)
                        .contextMenu {
                            if item.isDirectory { Button("Open Folder") { state.search = ""; model.browse(item.url) } }
                            Button("Reveal in Finder") { model.reveal(item.url) }
                            Button("Move to Trash…") { model.reviewCleanup([CleanupCandidate(url: item.url, bytes: item.allocatedBytes, reason: "Selected in File Browser")]) }
                        }
                        Divider()
                    }
                 }.padding(.horizontal, 16)
                }
            }
            if model.browserIsScanning { HStack { ProgressView().controlSize(.small); Text("Loading folder contents…").font(.caption); Spacer() }.padding(12) }
            HStack {
                Text(model.browserItems.count >= 10_000 ? "Showing the largest 10,000 indexed items. Refresh to measure this folder live." : "Allocated sizes include hidden files and package contents. Symbolic links are not followed.")
                Spacer()
                if model.browserUnreadable > 0 { Text("\(model.browserUnreadable) unreadable").foregroundStyle(.orange) }
            }.font(.caption2).foregroundStyle(.secondary).padding(12)
        }
    }
    private func fraction(_ item: ScanItem) -> CGFloat {
        model.browserTotal > 0 ? min(1, CGFloat(item.allocatedBytes) / CGFloat(model.browserTotal)) : 0
    }
}
