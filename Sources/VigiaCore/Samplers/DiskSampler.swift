import Foundation

public struct DiskMetrics: Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

public struct DiskSampler {
    /// En macOS moderno los datos del usuario viven en este volumen, no en `/`,
    /// que es de solo lectura y siempre se ve casi vacío.
    public static let dataVolume = "/System/Volumes/Data"

    private let path: String

    public init(path: String = DiskSampler.dataVolume) {
        self.path = path
    }

    public func sample() throws -> DiskMetrics {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            throw SamplerError.sysctlFailed("statfs \(path)")
        }
        let blockSize = UInt64(fs.f_bsize)
        return DiskMetrics(
            totalBytes: UInt64(fs.f_blocks) * blockSize,
            freeBytes: UInt64(fs.f_bavail) * blockSize
        )
    }
}
