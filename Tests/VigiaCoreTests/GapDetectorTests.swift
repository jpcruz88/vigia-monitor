import Foundation
import Testing
@testable import VigiaCore

@Test("El arnés de pruebas corre y MetricState conserva su valor")
func metricStateConservaValor() {
    let estado = MetricState<Int>.ok(42)
    #expect(estado.value == 42)

    let viejo = MetricState<Int>.stale(7, since: Date(timeIntervalSince1970: 0))
    #expect(viejo.value == 7)

    let ausente = MetricState<Int>.unavailable(reason: "prueba")
    #expect(ausente.value == nil)
}

/// Genera reportes regulares, todos con movimiento.
private func flujoRegular(intervalo: Double, cantidad: Int, desde: Double = 0) -> [PointerReport] {
    (0..<cantidad).map { PointerReport(timestamp: desde + Double($0) * intervalo, moved: true) }
}

@Test("Un flujo continuo y regular no produce ningún fallo")
func flujoContinuoSinFallos() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 500) {
        detector.record(reporte)
    }
    let salud = detector.health(now: 0.5)
    #expect(salud.faults == 0)
    #expect(salud.maxGapSeconds == 0)
}
