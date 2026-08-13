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
