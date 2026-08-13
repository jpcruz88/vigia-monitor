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
        // Una ruta que no existe: `Process.run()` lanza y el motor debe
        // degradar solo esa métrica. Se usa una ruta inexistente a propósito,
        // en vez de un comando que devuelva error, porque un comando que
        // termina bien pero sin salida produciría métricas vacías válidas y
        // la prueba pasaría sin ejercitar el camino de fallo.
        peripherals: PeripheralSampler(command: "/no/existe/vigia-prueba",
                                       arguments: [], timeout: 1)
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

@Test("El motor puede marcar el puntero como no disponible")
func punteroSeMarcaNoDisponible() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler()
    )
    await motor.updatePointer(PointerHealth(faults: 3, maxFaultGapSeconds: 0.05,
                                            expectedIntervalSeconds: 0.008))
    #expect(await motor.snapshot.pointer.value?.faults == 3)

    // Al desconectarse el mouse, la métrica debe dejar de afirmar que todo va bien.
    await motor.markPointerUnavailable(reason: "mouse desconectado")
    #expect(await motor.snapshot.pointer.value == nil)
}
