import Testing
import Foundation
@testable import VigiaCore

@Test("Un muestreador que falla no impide que los demás publiquen")
func falloAisladoNoTumbaElResto() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler(command: "/bin/false", arguments: [], timeout: 1)
    )
    await motor.refreshAll()
    let snapshot = await motor.snapshot

    // El de periféricos falla a propósito.
    #expect(snapshot.peripherals.value == nil)
    // Los demás deben seguir vivos.
    #expect(snapshot.memory.value != nil)
    #expect(snapshot.disk.value != nil)
}

@Test("Un valor previo se conserva marcado como viejo cuando el muestreo falla")
func valorPrevioSeConservaComoViejo() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler()
    )
    await motor.refreshPeripherals()
    let primero = await motor.snapshot.peripherals

    // Solo tiene sentido si la primera lectura funcionó.
    if primero.value != nil {
        await motor.markPeripheralsFailed(reason: "prueba")
        let segundo = await motor.snapshot.peripherals
        #expect(segundo.value != nil, "debe conservar el valor anterior")
        if case .stale = segundo {} else {
            Issue.record("se esperaba el estado viejo")
        }
    }
}
