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

@Test("Un hueco de 80 ms en medio del movimiento cuenta como un fallo")
func huecoCuentaComoFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    // 100 reportes normales, luego un salto de 80 ms, luego 100 más.
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100) {
        detector.record(reporte)
    }
    let despuesDelHueco = 0.100 + 0.080
    detector.record(PointerReport(timestamp: despuesDelHueco, moved: true))
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100, desde: despuesDelHueco + 0.001) {
        detector.record(reporte)
    }

    let salud = detector.health(now: 0.3)
    #expect(salud.faults == 1)
    #expect(abs(salud.maxGapSeconds - 0.080) < 0.001)
}

@Test("Los fallos salen de la ventana móvil al pasar 60 segundos")
func fallosExpiranDeLaVentana() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    detector.record(PointerReport(timestamp: 0, moved: true))
    detector.record(PointerReport(timestamp: 0.080, moved: true))
    #expect(detector.health(now: 0.1).faults == 1)
    // Ya pasó más de un minuto desde el fallo.
    #expect(detector.health(now: 61.0).faults == 0)
}

@Test("Diez segundos de reposo no cuentan como fallo")
func reposoNoEsFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100) {
        detector.record(reporte)
    }
    // El usuario suelta el mouse y vuelve diez segundos después.
    detector.record(PointerReport(timestamp: 10.0, moved: true))
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100, desde: 10.001) {
        detector.record(reporte)
    }
    #expect(detector.health(now: 10.2).faults == 0)
}

@Test("Un hueco tras un reporte sin movimiento no cuenta como fallo")
func huecoTrasReposoNoEsFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    detector.record(PointerReport(timestamp: 0, moved: true))
    // Un reporte sin desplazamiento, por ejemplo el de soltar un botón.
    detector.record(PointerReport(timestamp: 0.001, moved: false))
    detector.record(PointerReport(timestamp: 0.081, moved: true))
    #expect(detector.health(now: 0.1).faults == 0)
}
