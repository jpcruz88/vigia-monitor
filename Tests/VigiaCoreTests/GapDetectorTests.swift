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
