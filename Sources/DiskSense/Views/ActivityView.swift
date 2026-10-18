import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A trail you can follow back.").font(.title2.bold())
            Text("Cleanup activity stays on this Mac. Restore moves an item back only while it remains in its recorded Trash location, and never overwrites an existing file.")
                .font(.callout).foregroundStyle(.secondary)
            if model.cleanupHistory.isEmpty {
                InsightEmptyView(symbol: "clock.arrow.circlepath", title: "Nothing removed yet", message: "When you move items to Trash with DiskSense, their original paths, sizes and outcomes appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.cleanupHistory) { event in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "trash.circle.fill").font(.title2).foregroundStyle(.teal)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(event.receipts.count) item(s) · \(ByteFormat.string(event.movedBytes)) moved to Trash").font(.headline)
                                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                ForEach(event.receipts) { receipt in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(receipt.originalURL.lastPathComponent).font(.body.bold())
                                            Text(receipt.originalURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                                        }
                                        Spacer()
                                        Text(ByteFormat.string(receipt.bytes)).font(.caption.monospacedDigit())
                                        if event.restored.contains(receipt.id) {
                                            Label("Restored", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.teal)
                                        } else {
                                            if let trash = receipt.trashURL {
                                                Button("Reveal in Trash") { model.reveal(trash) }.controlSize(.small)
                                                Button("Restore") { model.restore(receipt, event: event) }.controlSize(.small).disabled(model.isCleaning)
                                            } else { Text("Use Finder to restore").font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                                ForEach(Array(event.failures.enumerated()), id: \.offset) { _, error in
                                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                                }
                            }.padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
        }.padding(22)
    }
}
