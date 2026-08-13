import Foundation

public struct MemoryMetrics: Sendable {
    public let totalBytes: UInt64
    /// Páginas verdaderamente libres. En macOS este número es siempre pequeño
    /// y por sí solo no dice nada: el sistema usa como caché toda la memoria
    /// que puede.
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    /// Caché de archivos que el sistema recupera al instante si hace falta.
    public let inactiveBytes: UInt64
    public let speculativeBytes: UInt64
    public let purgeableBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64

    /// Bytes realmente ocupados, con el mismo criterio que el Monitor de
    /// Actividad de macOS: memoria de aplicaciones, residente del kernel y
    /// comprimida. Deja fuera la caché reclamable, que es lo que hacía que
    /// este indicador marcara 99 % en todo momento.
    public let usedBytes: UInt64

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(totalBytes))
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

        // Criterio del Monitor de Actividad: páginas internas no purgables
        // (memoria de aplicaciones) + residente del kernel + comprimida.
        let internas = UInt64(stats.internal_page_count) * page
        let purgables = UInt64(stats.purgeable_count) * page
        let aplicaciones = internas > purgables ? internas - purgables : 0
        let usadas = aplicaciones + UInt64(stats.wire_count) * page
                   + UInt64(stats.compressor_page_count) * page

        return MemoryMetrics(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(stats.free_count) * page,
            activeBytes: UInt64(stats.active_count) * page,
            inactiveBytes: UInt64(stats.inactive_count) * page,
            speculativeBytes: UInt64(stats.speculative_count) * page,
            purgeableBytes: purgables,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total,
            usedBytes: usadas
        )
    }
}
