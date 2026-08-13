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
