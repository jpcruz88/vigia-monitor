import Foundation

/// Un reporte del mouse ya normalizado, independiente de IOKit.
/// Mantenerlo libre de tipos de IOKit es lo que permite probar el
/// algoritmo sin hardware.
public struct PointerReport: Sendable, Equatable {
    /// Marca de tiempo monotónica, en segundos.
    public let timestamp: Double
    /// true si el reporte trae desplazamiento distinto de cero.
    public let moved: Bool

    public init(timestamp: Double, moved: Bool) {
        self.timestamp = timestamp
        self.moved = moved
    }
}

/// Resultado del detector sobre la ventana móvil.
public struct PointerHealth: Sendable, Equatable {
    public let faults: Int
    public let maxGapSeconds: Double
    public let expectedIntervalSeconds: Double

    public init(faults: Int, maxGapSeconds: Double, expectedIntervalSeconds: Double) {
        self.faults = faults
        self.maxGapSeconds = maxGapSeconds
        self.expectedIntervalSeconds = expectedIntervalSeconds
    }
}

/// Detecta pérdidas de señal del mouse midiendo huecos entre reportes.
///
/// No es seguro para uso concurrente: `PointerHealthMonitor` lo confina
/// a una sola cola.
public final class GapDetector {
    /// Un hueco cuenta como fallo si supera este múltiplo del intervalo esperado.
    public static let gapMultiplier: Double = 4.0
    /// Ventana móvil de estadísticas, en segundos.
    public static let windowSeconds: Double = 60.0
    /// Intervalo supuesto mientras no hay datos suficientes (125 Hz).
    public static let bootstrapInterval: Double = 0.008

    private let declaredInterval: Double?
    private var observedIntervals: [Double] = []
    private var last: PointerReport?
    private var faults: [(at: Double, gap: Double)] = []

    /// - Parameter declaredIntervalSeconds: el `ReportInterval` que declara el
    ///   dispositivo. Si es `nil`, el detector usa la mediana observada.
    public init(declaredIntervalSeconds: Double?) {
        self.declaredInterval = declaredIntervalSeconds
    }

    public var expectedIntervalSeconds: Double {
        if let declaredInterval { return declaredInterval }
        guard !observedIntervals.isEmpty else { return Self.bootstrapInterval }
        let ordenados = observedIntervals.sorted()
        return ordenados[ordenados.count / 2]
    }

    public func record(_ report: PointerReport) {
        defer { last = report }
        guard let previo = last else { return }
        let hueco = report.timestamp - previo.timestamp
        guard hueco > 0 else { return }

        if hueco > expectedIntervalSeconds * Self.gapMultiplier {
            faults.append((at: report.timestamp, gap: hueco))
        } else {
            observedIntervals.append(hueco)
            if observedIntervals.count > 500 {
                observedIntervals.removeFirst(observedIntervals.count - 500)
            }
        }
        prune(now: report.timestamp)
    }

    public func health(now: Double) -> PointerHealth {
        prune(now: now)
        return PointerHealth(
            faults: faults.count,
            maxGapSeconds: faults.map(\.gap).max() ?? 0,
            expectedIntervalSeconds: expectedIntervalSeconds
        )
    }

    /// Descarta todo el estado acumulado. Se llama cuando el mouse se
    /// desconecta y cuando el Mac despierta.
    public func reset() {
        last = nil
        faults.removeAll()
        observedIntervals.removeAll()
    }

    private func prune(now: Double) {
        let corte = now - Self.windowSeconds
        faults.removeAll { $0.at < corte }
    }
}
