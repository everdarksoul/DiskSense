import Foundation
import Testing
@testable import DiskSense

struct TreemapTests {
    @Test func layoutCoversUnitAreaWithoutOverlapAtDifferentAspectRatios() {
        let values = (1...80).map { TreemapValue(id: String($0), bytes: Int64($0 * $0)) }
        for aspect in [0.5, 1, 1.8, 3.0] {
            let cells = TreemapLayout.cells(values, aspectRatio: aspect)
            #expect(cells.count == values.count)
            #expect(abs(cells.reduce(0.0) { $0 + $1.rect.width * $1.rect.height } - 1) < 0.000001)
            for (i, cell) in cells.enumerated() {
                #expect(cell.rect.minX >= -0.000001 && cell.rect.maxX <= 1.000001)
                #expect(cell.rect.minY >= -0.000001 && cell.rect.maxY <= 1.000001)
                for other in cells.dropFirst(i + 1) {
                    let intersection = cell.rect.intersection(other.rect)
                    #expect(intersection.isNull || intersection.width * intersection.height < 0.000001)
                }
            }
        }
    }
    @Test func zeroAndNegativeValuesDoNotCreateInvalidCells() {
        #expect(TreemapLayout.cells([TreemapValue(id: "zero", bytes: 0)]).isEmpty)
        let cells = TreemapLayout.cells([TreemapValue(id: "zero", bytes: 0), TreemapValue(id: "one", bytes: 100)])
        #expect(cells.count == 1)
        #expect(cells[0].rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
