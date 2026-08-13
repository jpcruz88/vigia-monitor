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
    /// El mayor de los huecos contados como fallo dentro de la ventana.
    /// Con cero fallos vale cero: no es el mayor hueco observado.
    public let maxFaultGapSeconds: Double
    public let expectedIntervalSeconds: Double

    public init(faults: Int, maxFaultGapSeconds: Double, expectedIntervalSeconds: Double) {
        self.faults = faults
        self.maxFaultGapSeconds = maxFaultGapSeconds
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
    /// Por encima de este hueco se considera pausa humana, no pérdida de señal.
    /// Una pérdida real del dongle dura decenas o pocos cientos de milisegundos.
    public static let humanPauseThreshold: Double = 0.5
    /// Intervalo supuesto mientras no hay nada mejor (125 Hz).
    public static let bootstrapInterval: Double = 0.008
    /// Muestras necesarias antes de fiarse de la mediana observada.
    public static let minimumSamples: Int = 20
    /// Cuántos huecos recientes se conservan para calcular la mediana.
    public static let sampleCapacity: Int = 500
    /// Rango de cordura del intervalo esperado: de 2000 Hz a 20 Hz.
    public static let minimumInterval: Double = 0.0005
    public static let maximumInterval: Double = 0.05

    private let declaredInterval: Double?
    private var observedIntervals: [Double] = []
    private var cachedExpected: Double?
    private var last: PointerReport?
    private var faults: [(at: Double, gap: Double)] = []

    /// - Parameter declaredIntervalSeconds: el `ReportInterval` que declara el
    ///   dispositivo. Si es `nil`, cero, negativo o no finito, el detector se
    ///   apoya solo en la mediana observada.
    public init(declaredIntervalSeconds: Double?) {
        // Un intervalo declarado que no sea finito y positivo no sirve: con
        // cero todo hueco sería fallo, y con NaN ninguna comparación se
        // cumpliría, así que el detector callaría para siempre.
        if let declarado = declaredIntervalSeconds, declarado.isFinite, declarado > 0 {
            declaredInterval = declarado
        } else {
            declaredInterval = nil
        }
    }

    /// true cuando hay muestras suficientes para fiarse de la mediana.
    private var isCalibrated: Bool {
        observedIntervals.count >= Self.minimumSamples
    }

    public var expectedIntervalSeconds: Double {
        if let cachedExpected { return cachedExpected }

        let base: Double
        if isCalibrated {
            let ordenados = observedIntervals.sorted()
            let mediana = ordenados[ordenados.count / 2]
            // Un receptor 2.4 GHz puede declarar 1 ms y entregar 8. Una vez
            // hay datos propios, el mayor de los dos es el que no produce
            // fallos falsos.
            base = max(declaredInterval ?? 0, mediana)
        } else {
            base = declaredInterval ?? Self.bootstrapInterval
        }

        let acotado = min(max(base, Self.minimumInterval), Self.maximumInterval)
        cachedExpected = acotado
        return acotado
    }

    public func record(_ report: PointerReport) {
        guard let previo = last else {
            last = report
            return
        }

        let hueco = report.timestamp - previo.timestamp
        // Un reporte fuera de orden no puede volverse la nueva referencia: el
        // siguiente hueco se mediría contra un instante anterior y saldría
        // inflado, produciendo un fallo que nunca ocurrió.
        guard hueco > 0 else { return }
        last = report

        // Solo cuenta si ocurre en medio de movimiento continuo. Esto deja un
        // punto ciego conocido: si el primer reporte que vuelve tras una
        // pérdida trae estado de botón en vez de desplazamiento, el corte no
        // se detecta. Se acepta a cambio de no contar como fallo cada pausa
        // breve del usuario, que es mucho más frecuente.
        guard previo.moved, report.moved else { return }
        // Un hueco enorme es el usuario soltando el mouse, no el dongle fallando.
        guard hueco < Self.humanPauseThreshold else { return }

        // Todo hueco plausible alimenta el estimador, incluidos los que se van
        // a contar como fallo. Si solo lo alimentaran los huecos que pasan el
        // umbral, el filtro dependería de su propia salida: una sola ráfaga
        // podría anclar la mediana y dejarla bloqueada para siempre.
        observedIntervals.append(hueco)
        if observedIntervals.count > Self.sampleCapacity {
            observedIntervals.removeFirst(observedIntervals.count - Self.sampleCapacity)
        }
        cachedExpected = nil

        // Sin intervalo declarado y sin muestras suficientes no hay con qué
        // juzgar: contar fallos aquí sería inventarlos durante el arranque.
        if declaredInterval != nil || isCalibrated {
            if hueco > expectedIntervalSeconds * Self.gapMultiplier {
                faults.append((at: report.timestamp, gap: hueco))
            }
        }
        prune(now: report.timestamp)
    }

    public func health(now: Double) -> PointerHealth {
        prune(now: now)
        return PointerHealth(
            faults: faults.count,
            maxFaultGapSeconds: faults.map(\.gap).max() ?? 0,
            expectedIntervalSeconds: expectedIntervalSeconds
        )
    }

    /// Descarta todo el estado acumulado. Se llama cuando el mouse se
    /// desconecta y cuando el Mac despierta.
    public func reset() {
        last = nil
        faults.removeAll()
        observedIntervals.removeAll()
        cachedExpected = nil
    }

    private func prune(now: Double) {
        let corte = now - Self.windowSeconds
        faults.removeAll { $0.at < corte }
    }
}
