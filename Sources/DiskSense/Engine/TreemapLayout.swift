import Foundation

struct TreemapValue { let id: String; let bytes: Int64 }
struct TreemapCell: Identifiable { let id: String; let rect: CGRect }

/// Squarified layout in unit coordinates. Geometry is independent of SwiftUI
/// so coverage, bounds and overlap can be verified without a renderer.
enum TreemapLayout {
    static func cells(_ values: [TreemapValue], aspectRatio: Double = 1) -> [TreemapCell] {
        let positive = values.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        let total = positive.reduce(0.0) { $0 + Double($1.bytes) }
        guard total > 0 else { return [] }
        let width = max(0.05, min(20, aspectRatio.isFinite ? aspectRatio : 1))
        var remaining = CGRect(x: 0, y: 0, width: width, height: 1)
        let scaled = positive.map { (id: $0.id, area: Double($0.bytes) / total * width) }
        var row: [(id: String, area: Double)] = []
        var result: [TreemapCell] = []
        func worst(_ row: [(id: String, area: Double)], _ side: Double) -> Double {
            guard let minimum = row.map(\.area).min(), let maximum = row.map(\.area).max(), minimum > 0, side > 0 else { return .infinity }
            let sum = row.reduce(0) { $0 + $1.area }
            return max(side * side * maximum / (sum * sum), sum * sum / (side * side * minimum))
        }
        func place() {
            guard !row.isEmpty else { return }
            let area = row.reduce(0) { $0 + $1.area }
            if remaining.width >= remaining.height {
                let strip = area / max(remaining.height, 1e-15)
                var y = remaining.minY
                for item in row {
                    let height = item.area / max(strip, 1e-15)
                    result.append(TreemapCell(id: item.id, rect: CGRect(x: remaining.minX / width, y: y, width: strip / width, height: height)))
                    y += height
                }
                remaining.origin.x += strip; remaining.size.width = max(0, remaining.width - strip)
            } else {
                let strip = area / max(remaining.width, 1e-15)
                var x = remaining.minX
                for item in row {
                    let itemWidth = item.area / max(strip, 1e-15)
                    result.append(TreemapCell(id: item.id, rect: CGRect(x: x / width, y: remaining.minY, width: itemWidth / width, height: strip)))
                    x += itemWidth
                }
                remaining.origin.y += strip; remaining.size.height = max(0, remaining.height - strip)
            }
            row = []
        }
        for item in scaled {
            let side = min(remaining.width, remaining.height)
            if !row.isEmpty && worst(row + [item], side) > worst(row, side) { place() }
            row.append(item)
        }
        place()
        return result
    }
}
