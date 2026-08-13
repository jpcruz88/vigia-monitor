import Testing
import Foundation
@testable import VigiaCore

@Test("MemorySampler devuelve cifras coherentes con el hardware")
func memoriaCoherente() throws {
    let metricas = try MemorySampler().sample()
    // El Mac mini objetivo tiene 16 GB; se acepta cualquier equipo de 4 GB en adelante.
    #expect(metricas.totalBytes > 4_000_000_000)
    #expect(metricas.freeBytes < metricas.totalBytes)
    #expect(metricas.swapUsedBytes <= metricas.swapTotalBytes)
    #expect(metricas.usedFraction >= 0 && metricas.usedFraction <= 1)
}

@Test("La fracción usada no cuenta la caché reclamable como memoria ocupada")
func memoriaNoCuentaCacheComoUsada() throws {
    let m = try MemorySampler().sample()
    let ingenua = Double(m.totalBytes - m.freeBytes) / Double(m.totalBytes)

    // Las páginas inactivas y especulativas son caché de archivos que macOS
    // recupera al instante. Contarlas como usadas clava el indicador cerca
    // del 100 % en todo momento y lo vuelve inútil.
    if m.inactiveBytes + m.speculativeBytes > 500_000_000 {
        #expect(m.usedFraction < ingenua - 0.05,
                "usada \(m.usedFraction) contra ingenua \(ingenua)")
    }
    // Un valor casi nulo delataría que la fórmula perdió términos.
    #expect(m.usedFraction > 0.05)
    #expect(m.usedFraction <= 1)
}

@Test("CPUSampler necesita dos muestras y luego da porcentajes válidos")
func cpuNecesitaDosMuestras() throws {
    let muestreador = CPUSampler()
    // La primera lectura solo siembra los contadores.
    #expect(try muestreador.sample() == nil)

    // Generar algo de trabajo para que los contadores avancen.
    var suma = 0.0
    for i in 0..<2_000_000 { suma += Double(i).squareRoot() }
    #expect(suma > 0)

    let metricas = try #require(try muestreador.sample())
    #expect(metricas.totalUsage >= 0 && metricas.totalUsage <= 1)
    #expect(metricas.performanceUsage >= 0 && metricas.performanceUsage <= 1)
    #expect(metricas.efficiencyUsage >= 0 && metricas.efficiencyUsage <= 1)
    #expect(metricas.coreCount > 0)
}

@Test("DiskSampler concuerda con el tamaño real del volumen")
func discoCoherente() throws {
    let metricas = try DiskSampler().sample()
    #expect(metricas.totalBytes > 10_000_000_000)
    #expect(metricas.freeBytes <= metricas.totalBytes)
    #expect(metricas.usedFraction >= 0 && metricas.usedFraction <= 1)
}

@Test("GPUSampler lee uso y memoria desde IORegistry")
func gpuCoherente() throws {
    let metricas = try GPUSampler().sample()
    #expect(metricas.utilization >= 0 && metricas.utilization <= 1)
    #expect(metricas.inUseMemoryBytes > 0)
}

@Test("PeripheralSampler respeta su límite de tiempo")
func perifericoRespetaLimite() async {
    // Un comando que nunca termina debe abortarse, no colgar la prueba.
    let muestreador = PeripheralSampler(command: "/bin/sleep", arguments: ["30"], timeout: 0.5)
    let inicio = Date()
    await #expect(throws: SamplerError.self) {
        _ = try await muestreador.runCommand()
    }
    #expect(Date().timeIntervalSince(inicio) < 5)
}

@Test("PeripheralSampler extrae la batería del teclado Bluetooth")
func perifericoLeeBateria() async throws {
    let muestreador = PeripheralSampler()
    let metricas = try await muestreador.sample()
    // Puede no haber teclado Bluetooth conectado; lo que no puede es lanzar error.
    if let bateria = metricas.keyboardBatteryPercent {
        #expect(bateria >= 0 && bateria <= 100)
    }
}
