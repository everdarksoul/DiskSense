import SwiftUI

final class FileSearchState: ObservableObject {
    @Published var text = ""
    @Published var minimumMB = 0
    @Published var category = "All categories"
    @Published var olderDays = 0
    @Published var includeFolders = false
    @Published var selected: Set<String> = []
    var signature: String { "\(text)|\(minimumMB)|\(category)|\(olderDays)|\(includeFolders)" }
}

struct FindFilesView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = FileSearchState()
    private var chosen: [CatalogEntry] { model.searchResults.filter { state.selected.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Find what you can let go.").font(.title2.bold())
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names and paths across this scan…", text: $state.text).textFieldStyle(.plain)
                    if model.isSearching { ProgressView().controlSize(.small) }
                }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                HStack(spacing: 14) {
                    Picker("Size", selection: $state.minimumMB) {
                        Text("Any size").tag(0); Text("100 MB+").tag(100); Text("500 MB+").tag(500); Text("1 GB+").tag(1000)
                    }.frame(width: 155)
                    Picker("Type", selection: $state.category) {
                        Text("All categories").tag("All categories")
                        ForEach(StorageCategory.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.frame(width: 185)
                    Picker("Modified", selection: $state.olderDays) {
                        Text("Any time").tag(0); Text("Over 90 days ago").tag(90); Text("Over a year ago").tag(365)
                    }.frame(width: 205)
                    Toggle("Include folders", isOn: $state.includeFolders).toggleStyle(.checkbox).font(.caption)
                }.controlSize(.small)
                HStack {
                    Text(state.text.isEmpty ? "Largest matching items · up to 200 results" : "\(model.searchResults.count) matches · up to 200 results").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !chosen.isEmpty { Text("\(chosen.count) selected").font(.caption.bold()) }
                    Button("Clear selection") { state.selected = [] }.disabled(chosen.isEmpty)
                    Button("Review Selected…") { model.reviewCleanup(chosen.map { CleanupCandidate(url: $0.url, bytes: $0.bytes, reason: "Selected from Find Files · sizes reflect the saved scan") }) }
                        .disabled(chosen.isEmpty || model.isCleaning)
                }.controlSize(.small)
            }.padding(20)
            Divider()
            if model.snapshot == nil {
                InsightEmptyView(symbol: "magnifyingglass", title: "Your search index is being built", message: "Complete a folder scan to search all of its files without scanning again.")
            } else if let error = model.searchError {
                InsightEmptyView(symbol: "exclamationmark.triangle", title: "Search could not finish", message: error)
            } else if model.searchResults.isEmpty && !model.isSearching {
                InsightEmptyView(symbol: "doc.text.magnifyingglass", title: "No matching files", message: "Try a shorter name or relax the size, category and date filters.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchResults) { entry in
                            CatalogResultRow(entry: entry, selected: Binding(get: { state.selected.contains(entry.id) }, set: { checked in
                                if checked { state.selected.insert(entry.id) } else { state.selected.remove(entry.id) }
                            }))
                            Divider()
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
        .onAppear { search() }
        .onChange(of: state.signature) { _ in state.selected = []; search() }
        .onChange(of: model.snapshot?.id) { _ in state.selected = []; search() }
    }
    private func search() {
        model.findFiles(text: state.text, minimumBytes: Int64(state.minimumMB) * 1_000_000,
            category: StorageCategory(rawValue: state.category), filesOnly: !state.includeFolders,
            olderThan: state.olderDays == 0 ? nil : Calendar.current.date(byAdding: .day, value: -state.olderDays, to: Date()))
    }
}

struct CatalogResultRow: View {
    @EnvironmentObject var model: AppModel
    let entry: CatalogEntry
    @Binding var selected: Bool
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(entry.name)", isOn: $selected).labelsHidden().toggleStyle(.checkbox)
            Image(systemName: entry.isDirectory ? "folder.fill" : entry.category.symbol).foregroundStyle(Color(hex: entry.category.colorHex) ?? .teal).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(.body.bold()).lineLimit(1)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(entry.path)
                HStack {
                    Text(entry.category.rawValue)
                    if entry.modified.timeIntervalSince1970 > 0 { Text("· Modified \(entry.modified.formatted(date: .abbreviated, time: .omitted))") }
                    if entry.unreadable > 0 { Text("· Partial size").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(entry.bytes)).font(.body.monospacedDigit()).frame(width: 105, alignment: .trailing)
            Button("Reveal") { model.reveal(entry.url) }.controlSize(.small)
            Button { model.browse(entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()) } label: { Image(systemName: "chevron.right") }.help("Browse containing folder")
        }.padding(.vertical, 12)
    }
}

struct InsightEmptyView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
