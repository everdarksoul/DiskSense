import SwiftUI

struct BreadcrumbBar: View {
    let root: URL
    let current: URL
    let open: (URL) -> Void
    private var crumbs: [URL] {
        guard current.path == root.path || current.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { return [current] }
        var result = [root]; var cursor = root
        for part in current.pathComponents.dropFirst(root.pathComponents.count) { cursor.appendPathComponent(part); result.append(cursor) }
        return result
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(crumbs, id: \.path) { url in
                    if url.path != crumbs.first?.path { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                    Button(url.path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : (url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)) { open(url) }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(url.path == current.path ? .primary : .secondary)
                }
            }.padding(.vertical, 3)
        }
    }
}

private struct MapTile: Identifiable {
    let id: String
    let name: String
    let bytes: Int64
    let entry: CatalogEntry?
    var color: Color { Color(hex: entry?.category.colorHex ?? "7EA398") ?? .teal }
}

struct SpaceMapView: View {
    @EnvironmentObject var model: AppModel
    private var tiles: [MapTile] {
        let entries = model.displayMapEntries.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        var tiles = entries.prefix(100).map { MapTile(id: $0.id, name: $0.name, bytes: $0.bytes, entry: $0) }
        if entries.count > 100 { tiles.append(MapTile(id: "disksense:remaining", name: "\(entries.count - 100) other items", bytes: entries.dropFirst(100).reduce(0) { $0 + $1.bytes }, entry: nil)) }
        return tiles
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A map of your space").font(.title2.bold())
                    Text("Larger tiles use more storage. Select to inspect; double-click a folder to zoom.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Browse folder") { model.browse(model.mapURL) }
            }
            ExplorerNavigationBar(location: model.mapURL)
            BreadcrumbBar(root: model.scanRoot, current: model.mapURL, open: { model.loadMap($0) })
            if let error = model.mapError {
                HStack { Label(error, systemImage: "lock.folder").font(.caption).foregroundStyle(.orange); Spacer(); Button("Try again") { model.loadMap(model.mapURL, refresh: true) } }
            }
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geometry in
                    let values = tiles.map { TreemapValue(id: $0.id, bytes: $0.bytes) }
                    let cells = TreemapLayout.cells(values, aspectRatio: geometry.size.width / max(1, geometry.size.height))
                    let lookup = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) })
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor))
                        ForEach(cells) { cell in
                            if let tile = lookup[cell.id] {
                                tileView(tile, width: cell.rect.width * geometry.size.width, height: cell.rect.height * geometry.size.height)
                                    .frame(width: max(0, cell.rect.width * geometry.size.width - 4), height: max(0, cell.rect.height * geometry.size.height - 4))
                                    .position(x: cell.rect.midX * geometry.size.width, y: cell.rect.midY * geometry.size.height)
                            }
                        }
                        if tiles.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "rectangle.3.group").font(.largeTitle)
                                if model.mapLoading { ProgressView(); Text("Measuring this folder…") }
                                else { Text(model.isScanning ? "The map fills as folders finish." : (model.mapError == nil ? "No allocated files in this folder." : "Folder unavailable")) }
                            }.foregroundStyle(.secondary).frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                }.frame(minHeight: 340)
                inspector.frame(width: 240)
            }.frame(maxHeight: .infinity)
            HStack(spacing: 14) {
                ForEach(StorageCategory.allCases) { category in
                    HStack(spacing: 5) { Circle().fill(Color(hex: category.colorHex) ?? .gray).frame(width: 7, height: 7); Text(category.rawValue) }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("\(ByteFormat.string(tiles.reduce(0) { $0 + $1.bytes })) in this view")
                Spacer()
                if model.mapLoading { ProgressView().controlSize(.mini) }
                if let measured = model.mapMeasuredAt { Text("Measured \(measured.formatted(date: .abbreviated, time: .shortened))") }
                else { Text("Live folder measurements · saved after the scan finishes") }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(22)
        .onAppear { model.loadMap(model.mapURL) }
    }

    private func tileView(_ tile: MapTile, width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(tile.color.gradient)
            if width > 60 && height > 32 {
                VStack(alignment: .leading, spacing: 5) {
                    if width > 95 && height > 80 { Image(systemName: tile.entry?.isDirectory == true ? "folder.fill" : "doc.fill").font(.title3).opacity(0.75) }
                    Text(tile.name).font(.system(size: width > 140 ? 14 : 11, weight: .semibold)).lineLimit(height > 95 ? 3 : 1)
                    if height > 50 { Text(ByteFormat.string(tile.bytes)).font(.caption).opacity(0.85) }
                }.foregroundStyle(.white).padding(width > 100 ? 13 : 7)
            }
            RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(model.mapSelected?.id == tile.id ? 1 : 0.18), lineWidth: model.mapSelected?.id == tile.id ? 3 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let entry = tile.entry, entry.isDirectory { model.loadMap(entry.url) }
            else if tile.entry == nil { model.browse(model.mapURL) }
        }
        .onTapGesture { if let entry = tile.entry { model.mapSelected = entry } else { model.browse(model.mapURL) } }
        .help("\(tile.name) · \(ByteFormat.string(tile.bytes))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.name), \(ByteFormat.string(tile.bytes))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if let entry = tile.entry { model.mapSelected = entry }
            else { model.browse(model.mapURL) }
        }
    }

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let entry = model.mapSelected {
                Image(systemName: entry.isDirectory ? "folder.fill" : entry.category.symbol).font(.system(size: 35)).foregroundStyle(Color(hex: entry.category.colorHex) ?? .teal)
                Text(entry.name).font(.title2.bold()).lineLimit(3)
                Text(ByteFormat.string(entry.bytes)).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                Text(entry.category.rawValue).font(.caption.bold()).foregroundStyle(.secondary)
                Text(entry.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(5).truncationMode(.middle)
                if entry.logicalBytes > 0 && !entry.isDirectory && entry.logicalBytes != entry.bytes {
                    Text("Logical size: \(ByteFormat.string(entry.logicalBytes))").font(.caption).foregroundStyle(.secondary)
                }
                if entry.modified.timeIntervalSince1970 > 0 { Text("Modified \(entry.modified.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                if entry.unreadable > 0 { Label("Partial size · \(entry.unreadable) unreadable", systemImage: "lock").font(.caption).foregroundStyle(.orange) }
                Divider()
                if entry.isDirectory { Button("Explore folder") { model.loadMap(entry.url) }.buttonStyle(.borderedProminent) }
                Button("Reveal in Finder") { model.reveal(entry.url) }
                Button("Review for Trash…") { model.reviewCleanup([CleanupCandidate(url: entry.url, bytes: entry.bytes, reason: "Selected from the Space Map")]) }.disabled(model.isCleaning)
            } else {
                Image(systemName: "cursorarrow.rays").font(.largeTitle).foregroundStyle(.secondary)
                Text("Follow the big pieces.").font(.title3.bold())
                Text("Select a tile to see its size, location and actions. Folder totals include their contents.").font(.callout).foregroundStyle(.secondary)
                Divider()
                Text("Measured allocation can differ from space reclaimed because of APFS sharing and snapshots.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
