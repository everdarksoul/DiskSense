import SwiftUI

final class AppsState: ObservableObject { @Published var search = "" }
final class AppRowState: ObservableObject { @Published var expanded = false }

struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var state = AppsState()
    private var filtered: [AppEntry] {
        model.apps.filter { state.search.isEmpty || $0.name.localizedCaseInsensitiveContains(state.search) || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(state.search) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search applications…", text: $state.search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Text("\(filtered.count) apps · \(ByteFormat.string(model.totalAppBytes))").font(.callout.bold())
            }.padding(16)
            Text("Applications on this Mac, regardless of the selected scan folder. Sorted by installed size. Related files and uninstall actions open a review.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if model.apps.isEmpty {
                VStack(spacing: 12) {
                    if model.isScanning && !model.completedStages.contains("Apps") { ProgressView(); Text("Measuring installed applications and related files…") }
                    else { Image(systemName: "app.dashed").font(.largeTitle); Text("No applications found.") }
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in AppRow(app: app); Divider() }
                    }.padding(.horizontal, 18)
                }
            }
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppEntry
    @StateObject private var state = AppRowState()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "app.fill").font(.title2).foregroundStyle(.blue).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.body.bold())
                    Text(app.bundleIdentifier ?? app.appURL.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Button(state.expanded ? "Hide related files" : "Related files (\(app.relatedFiles.count))") { state.expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormat.string(app.allocatedBytes)).font(.body.monospacedDigit())
                    if !app.relatedFiles.isEmpty { Text("+ \(ByteFormat.string(app.relatedBytes)) related").font(.caption2).foregroundStyle(.orange) }
                }.frame(minWidth: 100)
                Button("Reveal") { model.reveal(app.appURL) }.controlSize(.small)
                Button("Uninstall…") { model.reviewApp(app) }.controlSize(.small)
                    .disabled(app.appURL.path.hasPrefix("/System/") || app.appURL.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL || model.isCleaning)
            }.padding(.vertical, 12)
            if state.expanded {
                if app.relatedFiles.isEmpty { Text("No matching support files found in accessible folders.").font(.caption).foregroundStyle(.secondary).padding(8) }
                ForEach(app.relatedFiles) { file in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.category.rawValue).font(.caption.bold())
                            Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(file.path)
                        }
                        Spacer()
                        Text(ByteFormat.string(file.bytes)).font(.caption.monospacedDigit())
                        Button("Reveal") { model.reveal(URL(fileURLWithPath: file.path)) }.controlSize(.small)
                        Button("Review…") { model.reviewCleanup([CleanupCandidate(url: URL(fileURLWithPath: file.path), bytes: file.bytes, reason: "Possible related \(file.category.rawValue.lowercased()) for \(app.name)")]) }.controlSize(.small)
                    }.padding(.leading, 44).padding(.vertical, 6)
                }
            }
        }.accessibilityElement(children: .contain)
    }
}
