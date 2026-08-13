import Foundation

/// Coordina los muestreadores, aísla sus fallos y publica un snapshot.
///
/// Es un actor: los muestreadores se leen desde tareas distintas y el
/// snapshot se lee desde la interfaz.
public actor MetricsEngine {
    public private(set) var snapshot: SystemSnapshot = .empty

    private let memory: MemorySampler
    private let cpu: CPUSampler
    private let gpu: GPUSampler
    private let disk: DiskSampler
    private let peripherals: PeripheralSampler

    public init(
        memory: MemorySampler,
        cpu: CPUSampler,
        gpu: GPUSampler,
        disk: DiskSampler,
        peripherals: PeripheralSampler
    ) {
        self.memory = memory
        self.cpu = cpu
        self.gpu = gpu
        self.disk = disk
        self.peripherals = peripherals
    }

    /// Aplica un muestreo conservando el valor anterior si falla.
    private func apply<T>(
        _ estado: inout MetricState<T>,
        _ leer: () throws -> T?
    ) {
        do {
            if let valor = try leer() {
                estado = .ok(valor)
            }
            // Un nil no es un fallo: significa "aún no hay dato", como la
            // primera muestra de CPU. Se deja el estado como está.
        } catch {
            degrade(&estado, reason: String(describing: error))
        }
    }

    private func degrade<T>(_ estado: inout MetricState<T>, reason: String) {
        if let previo = estado.value {
            estado = .stale(previo, since: Date())
        } else {
            estado = .unavailable(reason: reason)
        }
    }

    public func refreshFast() {
        apply(&snapshot.memory) { try memory.sample() }
        apply(&snapshot.cpu) { try cpu.sample() }
        apply(&snapshot.gpu) { try gpu.sample() }
        snapshot.capturedAt = Date()
    }

    public func refreshDisk() {
        apply(&snapshot.disk) { try disk.sample() }
    }

    /// El muestreo de periféricos lanza un proceso externo que tarda
    /// segundos. Se espera **fuera** del aislamiento del actor: `sample()` es
    /// `async` y `PeripheralSampler` es una `struct` `Sendable`, así que la
    /// llamada no corre en el ejecutor del actor y la suspensión lo deja
    /// libre para seguir atendiendo lecturas del snapshot. Muestrear dentro
    /// del aislamiento congelaba el panel entero hasta diez segundos.
    public func refreshPeripherals() async {
        let resultado: Result<PeripheralMetrics, Error>
        do {
            resultado = .success(try await peripherals.sample())
        } catch {
            resultado = .failure(error)
        }
        // De vuelta en el actor, ya con el resultado en la mano.
        apply(&snapshot.peripherals) { try resultado.get() }
    }

    public func refreshAll() async {
        refreshFast()
        refreshDisk()
        await refreshPeripherals()
    }

    public func updatePointer(_ salud: PointerHealth) {
        snapshot.pointer = .ok(salud)
    }

    public func markPointerUnavailable(reason: String) {
        snapshot.pointer = .unavailable(reason: reason)
    }

    /// Expuesto para las pruebas de degradación.
    public func markPeripheralsFailed(reason: String) {
        degrade(&snapshot.peripherals, reason: reason)
    }

    /// Descarta el estado acumulado. Se llama al despertar del sueño: sin
    /// esto, la primera diferencia de CPU produce un pico falso.
    public func resetAccumulators() {
        cpu.reset()
    }
}
