import SwiftUI

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Room for what’s next.").font(.system(size: 31, weight: .bold, design: .rounded))
                        Text(model.isBootstrapping ? "Reopening your last scan…" : "Understand what takes space. Choose what stays.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.mapURL = model.scanRoot; model.selection = .spaceMap } label: { Label("Explore Space Map", systemImage: "rectangle.3.group.fill") }.buttonStyle(.borderedProminent).tint(.teal)
                }
                HStack(spacing: 14) {
                    metric("Volume available", value: model.isBootstrapping && model.overview.totalCapacity == 0 ? "—" : ByteFormat.string(model.overview.freeSpace), detail: "of \(ByteFormat.string(model.overview.totalCapacity))", symbol: "internaldrive", color: .teal)
                    metric("Measured in \(model.rootName)", value: model.isBootstrapping ? "Opening…" : ByteFormat.string(model.overview.scannedBytes), detail: model.isScanning ? "Updates as folders complete" : "\(model.scannedItemCount.formatted()) indexed entries", symbol: "folder.fill", color: .indigo)
                    metric("Home cache candidates", value: model.junk.isEmpty && model.isScanning ? "Measuring…" : ByteFormat.string(model.totalJunkBytes), detail: "Review \(model.junk.count) items before removing", symbol: "sparkles", color: .orange)
                }
                if !model.categoryTotals.isEmpty { composition }
                HStack(spacing: 12) {
                    action("Find large files", subtitle: "Search by name, size, type or age", symbol: "magnifyingglass", color: .indigo) { model.selection = .search }
                    action("What changed?", subtitle: model.previousSnapshot == nil ? "Compare after your next scan" : "\(model.changes.count) top-level items changed", symbol: "arrow.up.arrow.down", color: .teal) { model.selection = .changes }
                    action("Make room", subtitle: "Choose a goal. Build a cleanup plan.", symbol: "sparkles", color: .orange) { model.selection = .plan }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Largest folders & files").font(.title3.bold())
                        Text("\(model.homeBreakdown.count) immediate items in \(model.rootName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Browse all") { model.browse(model.scanRoot) }
                }
                if model.homeBreakdown.isEmpty {
                    InsightEmptyView(symbol: "folder", title: model.isBootstrapping ? "Preparing your workspace…" : (model.isScanning ? "Measuring the first folder…" : "No accessible items"), message: model.isBootstrapping ? "Saved indexes are being opened or optimized. Your files are unchanged." : "You can choose another folder or volume from the sidebar.").frame(height: 140)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.homeBreakdown.prefix(10)) { item in
                            Button { if item.isDirectory { model.browse(item.url) } else { model.reveal(item.url) } } label: { SizeRow(item: item, total: model.overview.scannedBytes) }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                HStack(spacing: 12) {
                    action("Find duplicate copies", subtitle: "Verify identical content, keep an original", symbol: "square.on.square", color: .indigo) { model.selection = .duplicates }
                    action("Your cleanup story", subtitle: "Review history and restore from Trash", symbol: "clock.arrow.circlepath", color: .teal) { model.selection = .history }
                }
                if !model.largestFiles.isEmpty { largestFiles }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text("Measured sizes are allocated storage, not a promise of space reclaimed. Volume usage also includes macOS, other folders and snapshots. DiskSense’s own index is excluded from indexed scans. Trash still occupies storage until emptied.")
                }.font(.caption).foregroundStyle(.secondary)
                if model.overview.unreadableCount > 0 {
                    Label("\(model.overview.unreadableCount) entries could not be read. Those locations are marked; totals are partial.", systemImage: "lock").font(.caption).foregroundStyle(.orange)
                }
            }.padding(24)
        }
    }
    private func metric(_ title: String, value: String, detail: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.caption.bold()).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(color) }
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).minimumScaleFactor(0.65).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15).fill(color.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(color.opacity(0.13)))
    }
    private var composition: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What your files are made of").font(.caption.bold()).foregroundStyle(.secondary)
            GeometryReader { geo in
                let total = max(1, model.categoryTotals.reduce(0) { $0 + $1.bytes })
                HStack(spacing: 2) {
                    ForEach(model.categoryTotals) { category in
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: category.category.colorHex) ?? .teal)
                            .frame(width: max(0, (geo.size.width - CGFloat(model.categoryTotals.count - 1) * 2) * CGFloat(category.bytes) / CGFloat(total)))
                            .help("\(category.category.rawValue): \(ByteFormat.string(category.bytes))")
                    }
                }
            }.frame(height: 12)
            HStack(spacing: 14) {
                ForEach(model.categoryTotals) { total in
                    HStack(spacing: 4) { Circle().fill(Color(hex: total.category.colorHex) ?? .teal).frame(width: 6, height: 6); Text("\(total.category.rawValue) \(ByteFormat.string(total.bytes))") }.font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func action(_ title: String, subtitle: String, symbol: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.title3).foregroundStyle(color).frame(width: 22)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.callout.bold()); Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                Spacer(minLength: 0)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        }.buttonStyle(.plain)
    }
    private var largestFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Big files worth a look").font(.title3.bold()); Spacer(); Button("Find more") { model.selection = .search } }
            ForEach(model.largestFiles.prefix(5)) { entry in
                HStack {
                    Image(systemName: entry.category.symbol).foregroundStyle(Color(hex: entry.category.colorHex) ?? .teal).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) { Text(entry.name).font(.callout.bold()).lineLimit(1); Text(entry.parent).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    Spacer()
                    Text(ByteFormat.string(entry.bytes)).font(.callout.monospacedDigit())
                    Button("Reveal") { model.reveal(entry.url) }.controlSize(.small)
                }.padding(.vertical, 5)
            }
        }
    }
}

struct SizeRow: View {
    let item: ScanItem
    let total: Int64
    private var color: Color { Color(hex: StorageCategory.classify(path: item.url.path, isDirectory: item.isDirectory).colorHex) ?? .teal }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isPackage ? "shippingbox.fill" : (item.isDirectory ? "folder.fill" : "doc")).foregroundStyle(color).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(item.name).font(.body.bold()).lineLimit(1); if item.isUnreadable { Image(systemName: "lock").foregroundStyle(.orange).help("Partial size") } }
                GeometryReader { geo in Capsule().fill(color.opacity(0.55)).frame(width: max(2, geo.size.width * fraction), height: 5) }.frame(height: 5)
            }
            Text(ByteFormat.string(item.allocatedBytes)).font(.body.monospacedDigit()).frame(width: 110, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12).contentShape(Rectangle())
    }
    private var fraction: CGFloat { total > 0 ? min(1, CGFloat(item.allocatedBytes) / CGFloat(total)) : 0 }
}

extension Color {
    init?(hex: String) {
        let hex = hex.replacingOccurrences(of: "#", with: "")
        guard let value = UInt64(hex, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
