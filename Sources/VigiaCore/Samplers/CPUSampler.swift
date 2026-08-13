import Foundation

public struct CPUMetrics: Sendable {
    /// Fracción ocupada de todos los núcleos, entre 0 y 1.
    public let totalUsage: Double
    /// Fracción ocupada solo de los núcleos de rendimiento.
    public let performanceUsage: Double
    /// Fracción ocupada solo de los núcleos de eficiencia.
    public let efficiencyUsage: Double
    public let coreCount: Int
}

/// Lee los contadores acumulados de CPU y calcula el uso por diferencia.
///
/// No es seguro para uso concurrente: guarda la muestra anterior.
public final class CPUSampler {
    private var previous: [(busy: Double, total: Double)] = []
    private let efficiencyCoreCount: Int
    private let performanceCoreCount: Int

    public init() {
        performanceCoreCount = CPUSampler.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCoreCount = CPUSampler.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    /// Descarta la muestra anterior. Obligatorio tras despertar del sueño:
    /// la diferencia contra una muestra de antes de dormir da un pico falso.
    public func reset() {
        previous = []
    }

    /// Devuelve `nil` en la primera llamada, cuando aún no hay con qué comparar.
    public func sample() throws -> CPUMetrics? {
        let actual = try Self.readCounters()
        defer { previous = actual }
        guard !previous.isEmpty, previous.count == actual.count else { return nil }

        var porNucleo: [Double] = []
        for (anterior, ahora) in zip(previous, actual) {
            let deltaTotal = ahora.total - anterior.total
            let deltaBusy = ahora.busy - anterior.busy
            porNucleo.append(deltaTotal > 0 ? max(0, min(1, deltaBusy / deltaTotal)) : 0)
        }

        // En Apple Silicon los núcleos de eficiencia ocupan los primeros
        // índices del arreglo y los de rendimiento los últimos.
        let e = min(efficiencyCoreCount, porNucleo.count)
        let eficiencia = Array(porNucleo.prefix(e))
        let rendimiento = Array(porNucleo.dropFirst(e))

        return CPUMetrics(
            totalUsage: promedio(porNucleo),
            performanceUsage: promedio(rendimiento),
            efficiencyUsage: promedio(eficiencia),
            coreCount: porNucleo.count
        )
    }

    private func promedio(_ valores: [Double]) -> Double {
        guard !valores.isEmpty else { return 0 }
        return valores.reduce(0, +) / Double(valores.count)
    }

    private static func readCounters() throws -> [(busy: Double, total: Double)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                    &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            throw SamplerError.machCall("host_processor_info", kr)
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var resultado: [(busy: Double, total: Double)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let sistema = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            let ocupado = user + sistema + nice
            resultado.append((busy: ocupado, total: ocupado + idle))
        }
        return resultado
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var valor: Int32 = 0
        var tamano = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &valor, &tamano, nil, 0) == 0 else { return nil }
        return Int(valor)
    }
}
