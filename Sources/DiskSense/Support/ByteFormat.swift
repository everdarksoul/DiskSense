import Foundation

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        fmt.allowedUnits = useAutomatic(bytes)
        return fmt.string(fromByteCount: bytes)
    }

    private static func useAutomatic(_ bytes: Int64) -> ByteCountFormatter.Units {
        return .useAll
    }

    /// Human string for a size in a specific unit (used for color-bucket labels).
    static func string(_ bytes: Int64, units: ByteCountFormatter.Units) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        fmt.allowedUnits = units
        return fmt.string(fromByteCount: bytes)
    }
}

/// Size buckets — the OmniDiskSweeper color-by-size idea, generalized.
enum SizeBucket: Int, Comparable, CaseIterable {
    case bytes      // < 1 MB
    case kilobytes  // < 1 MB
    case megabytes  // < 1 GB
    case gigabytes  // < 1 TB
    case terabytes

    static func < (lhs: SizeBucket, rhs: SizeBucket) -> Bool { lhs.rawValue < rhs.rawValue }

    static func bucket(for bytes: Int64) -> SizeBucket {
        switch bytes {
        case ..<1_000_000: return .kilobytes
        case ..<1_000_000_000: return .megabytes
        case ..<1_000_000_000_000: return .gigabytes
        default: return .terabytes
        }
    }

    var colorHex: String {
        switch self {
        case .bytes, .kilobytes: return "#8E8E93"   // systemGray
        case .megabytes:         return "#007AFF"   // systemBlue
        case .gigabytes:         return "#FF9500"   // systemOrange
        case .terabytes:         return "#FF3B30"   // systemRed
        }
    }
}
