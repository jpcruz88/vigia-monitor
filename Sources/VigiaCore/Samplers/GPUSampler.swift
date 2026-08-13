import Foundation
import IOKit

public struct GPUMetrics: Sendable {
    /// Fracción de uso del dispositivo, entre 0 y 1.
    public let utilization: Double
    public let inUseMemoryBytes: UInt64
    public let allocatedMemoryBytes: UInt64
}

public struct GPUSampler {
    private static let statisticsKey = "PerformanceStatistics"
    private static let utilizationKey = "Device Utilization %"
    private static let inUseKey = "In use system memory"
    private static let allocatedKey = "Alloc system memory"

    public init() {}

    public func sample() throws -> GPUMetrics {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        )
        guard kr == KERN_SUCCESS else {
            throw SamplerError.machCall("IOServiceGetMatchingServices", kr)
        }
        defer { IOObjectRelease(iterator) }

        while case let servicio = IOIteratorNext(iterator), servicio != 0 {
            defer { IOObjectRelease(servicio) }
            guard let props = IORegistryEntryCreateCFProperty(
                servicio, Self.statisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            guard let uso = props[Self.utilizationKey] as? Int else { continue }
            let enUso = props[Self.inUseKey] as? Int ?? 0
            let reservada = props[Self.allocatedKey] as? Int ?? 0

            return GPUMetrics(
                utilization: min(1, max(0, Double(uso) / 100)),
                inUseMemoryBytes: UInt64(max(0, enUso)),
                allocatedMemoryBytes: UInt64(max(0, reservada))
            )
        }
        throw SamplerError.registryKeyMissing(Self.statisticsKey)
    }
}
