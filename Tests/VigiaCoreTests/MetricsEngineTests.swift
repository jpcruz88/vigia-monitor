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
        await motor.markFailed(.peripherals, reason: "prueba")
        let segundo = await motor.snapshot.peripherals
        #expect(segundo.value != nil, "debe conservar el valor anterior")
        if case .stale = segundo {} else {
            Issue.record("se esperaba el estado viejo")
        }
    }
}

@Test("Un muestreo lento de periféricos no bloquea la lectura del snapshot")
func perifericosLentosNoBloqueanElSnapshot() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler(command: "/bin/sleep", arguments: ["3"], timeout: 5)
    )
    await motor.refreshFast()

    // Arranca el muestreo lento sin esperarlo.
    let lento = Task { await motor.refreshPeripherals() }

    // El snapshot debe seguir siendo legible mientras aquello ocurre.
    let inicio = Date()
    _ = await motor.snapshot
    let transcurrido = Date().timeIntervalSince(inicio)
    #expect(transcurrido < 1.0,
            "leer el snapshot tardó \(transcurrido) s: el actor estaba bloqueado")

    _ = await lento.value
}

@Test("Al despertar del sueño la CPU no se publica como fresca")
func cpuTrasDespertarNoEsFresca() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(), cpu: CPUSampler(), gpu: GPUSampler(),
        disk: DiskSampler(), peripherals: PeripheralSampler()
    )
    // Dos refrescos para que la CPU tenga con qué comparar.
    await motor.refreshFast()
    await motor.refreshFast()
    guard case .ok = await motor.snapshot.cpu else {
        Issue.record("se esperaba una lectura de CPU válida")
        return
    }

    // Despertar del sueño descarta los contadores.
    await motor.resetAccumulators()
    await motor.refreshFast()

    if case .ok = await motor.snapshot.cpu {
        Issue.record("la CPU de antes de dormir se publicó como fresca")
    }
}

@Test("Un valor ya viejo conserva su sello de antigüedad")
func selloDeAntiguedadNoSeRenueva() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(), cpu: CPUSampler(), gpu: GPUSampler(),
        disk: DiskSampler(), peripherals: PeripheralSampler()
    )
    await motor.refreshDisk()
    guard case .ok = await motor.snapshot.disk else {
        Issue.record("se esperaba una lectura de disco válida")
        return
    }

    await motor.markFailed(.disk, reason: "primera caída")
    guard case .stale(_, let primerSello) = await motor.snapshot.disk else {
        Issue.record("se esperaba el estado viejo")
        return
    }

    try await Task.sleep(for: .milliseconds(50))
    await motor.markFailed(.disk, reason: "segunda caída")
    guard case .stale(_, let segundoSello) = await motor.snapshot.disk else {
        Issue.record("se esperaba seguir en estado viejo")
        return
    }
    #expect(primerSello == segundoSello, "el sello se renovó y miente sobre la antigüedad")
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
