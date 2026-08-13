import Foundation

public struct MemoryMetrics: Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let compressedBytes: UInt64
    public let wiredBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64

    /// Fracción de la RAM que no está libre, entre 0 y 1.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

public struct MemorySampler {
    public init() {}

    public func sample() throws -> MemoryMetrics {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw SamplerError.machCall("host_statistics64", kr)
        }

        let page = UInt64(getpagesize())
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else {
            throw SamplerError.sysctlFailed("vm.swapusage")
        }

        return MemoryMetrics(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(stats.free_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total
        )
    }
}
