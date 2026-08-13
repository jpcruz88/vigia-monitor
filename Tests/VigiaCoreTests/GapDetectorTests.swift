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
    #expect(salud.maxFaultGapSeconds == 0)
}

@Test("Un hueco de 80 ms en medio del movimiento cuenta como un fallo")
func huecoCuentaComoFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    let regulares = flujoRegular(intervalo: 0.001, cantidad: 100)
    for reporte in regulares {
        detector.record(reporte)
    }
    // Partir del último reporte emitido, no de un valor supuesto.
    let ultimo = regulares.last!.timestamp
    let hueco = 0.080
    let despuesDelHueco = ultimo + hueco
    detector.record(PointerReport(timestamp: despuesDelHueco, moved: true))
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100, desde: despuesDelHueco + 0.001) {
        detector.record(reporte)
    }

    let salud = detector.health(now: despuesDelHueco + 0.2)
    #expect(salud.faults == 1)
    #expect(abs(salud.maxFaultGapSeconds - hueco) < 1e-6)
}

@Test("Los fallos salen de la ventana móvil al pasar 60 segundos")
func fallosExpiranDeLaVentana() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    // Calibrar primero: sin muestras propias no se cuenta ningún fallo.
    let regulares = flujoRegular(intervalo: 0.001, cantidad: 30)
    for reporte in regulares {
        detector.record(reporte)
    }
    let fallo = regulares.last!.timestamp + 0.080
    detector.record(PointerReport(timestamp: fallo, moved: true))
    #expect(detector.health(now: fallo + 0.02).faults == 1)
    // Ya pasó más de un minuto desde el fallo.
    #expect(detector.health(now: fallo + 61.0).faults == 0)
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
    // Calibrar primero, para que la prueba ejercite de verdad la guarda de
    // movimiento y no pase solo porque el detector aún no juzga nada.
    let regulares = flujoRegular(intervalo: 0.001, cantidad: 30)
    for reporte in regulares {
        detector.record(reporte)
    }
    let ultimo = regulares.last!.timestamp
    // Un reporte sin desplazamiento, por ejemplo el de soltar un botón.
    detector.record(PointerReport(timestamp: ultimo + 0.001, moved: false))
    detector.record(PointerReport(timestamp: ultimo + 0.081, moved: true))
    #expect(detector.health(now: ultimo + 0.2).faults == 0)
}

@Test("Sin intervalo declarado, una ráfaga inicial no ancla el estimador")
func rafagaInicialNoAnclaElEstimador() {
    // Un hub USB puede entregar dos reportes en la misma transferencia.
    // El diseño anterior tomaba ese 0.2 ms como intervalo esperado y a
    // partir de ahí contaba cada reporte real como fallo, para siempre.
    let detector = GapDetector(declaredIntervalSeconds: nil)
    detector.record(PointerReport(timestamp: 0, moved: true))
    detector.record(PointerReport(timestamp: 0.0002, moved: true))
    for reporte in flujoRegular(intervalo: 0.008, cantidad: 200, desde: 0.0082) {
        detector.record(reporte)
    }

    let salud = detector.health(now: 2.0)
    #expect(salud.faults == 0)
    #expect(abs(salud.expectedIntervalSeconds - 0.008) < 0.0005)
}

@Test("Sin intervalo declarado, un dispositivo lento no genera fallos falsos")
func dispositivoLentoNoGeneraFallosFalsos() {
    // 50 ms por reporte (20 Hz) supera el intervalo de arranque de 8 ms.
    // El diseño anterior contaba cada uno de sus reportes como fallo.
    let detector = GapDetector(declaredIntervalSeconds: nil)
    for reporte in flujoRegular(intervalo: 0.05, cantidad: 100) {
        detector.record(reporte)
    }
    #expect(detector.health(now: 5.0).faults == 0)
}

@Test("Un intervalo declarado inválido se trata como ausente")
func intervaloDeclaradoInvalido() {
    for invalido in [0.0, -1.0, Double.nan, Double.infinity] {
        let detector = GapDetector(declaredIntervalSeconds: invalido)
        for reporte in flujoRegular(intervalo: 0.008, cantidad: 100) {
            detector.record(reporte)
        }
        let salud = detector.health(now: 1.0)
        #expect(salud.faults == 0, "con \(invalido) no debería inventar fallos")
        #expect(salud.expectedIntervalSeconds.isFinite)
        #expect(salud.expectedIntervalSeconds > 0)
    }
}

@Test("Un intervalo declarado que miente no produce fallos perpetuos")
func intervaloDeclaradoQueMiente() {
    // El receptor declara 1 ms pero entrega 8 ms.
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.008, cantidad: 200) {
        detector.record(reporte)
    }
    // No hay ni un fallo: el detector no juzga nada hasta estar calibrado, y
    // en cuanto lo está manda la mediana observada, no el dato declarado.
    let salud = detector.health(now: 2.0)
    #expect(salud.faults == 0, "el dato declarado no debe producir fallos, hubo \(salud.faults)")
    #expect(abs(salud.expectedIntervalSeconds - 0.008) < 0.0005)
}

@Test("Reiniciar deja el detector como recién creado")
func reiniciarDejaEstadoLimpio() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    // Calibrar primero: sin muestras propias no se cuenta ningún fallo.
    let regulares = flujoRegular(intervalo: 0.001, cantidad: 30)
    for reporte in regulares {
        detector.record(reporte)
    }
    let fallo = regulares.last!.timestamp + 0.080
    detector.record(PointerReport(timestamp: fallo, moved: true))
    #expect(detector.health(now: fallo + 0.02).faults == 1)

    detector.reset()
    #expect(detector.health(now: fallo + 0.02).faults == 0)
    // Tras reiniciar no debe medirse un hueco a caballo del corte.
    detector.record(PointerReport(timestamp: 100.0, moved: true))
    #expect(detector.health(now: 100.1).faults == 0)
}

@Test("El umbral del multiplicador se aplica de forma estricta")
func umbralDelMultiplicadorEsEstricto() {
    // Con un flujo de 1 ms la mediana observada vale 1 ms, igual que el dato
    // declarado, así que el umbral es exactamente 4 ms.
    let calibracion = flujoRegular(intervalo: 0.001, cantidad: 30)
    let ultimo = calibracion.last!.timestamp

    let justo = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in calibracion {
        justo.record(reporte)
    }
    justo.record(PointerReport(timestamp: ultimo + 0.004, moved: true))
    #expect(justo.health(now: ultimo + 0.1).faults == 0, "un hueco de exactamente 4x no es fallo")

    let pasado = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in calibracion {
        pasado.record(reporte)
    }
    pasado.record(PointerReport(timestamp: ultimo + 0.0041, moved: true))
    #expect(pasado.health(now: ultimo + 0.1).faults == 1, "por encima de 4x sí es fallo")
}

@Test("Tras reiniciar, un dispositivo que miente no produce una ráfaga de fallos")
func reinicioNoProduceRafagaDeFallos() {
    // El receptor declara 1 ms y entrega 8. Antes, cada reinicio —cada
    // despertar del Mac— producía una ráfaga de fallos falsos.
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.008, cantidad: 100) {
        detector.record(reporte)
    }
    #expect(detector.health(now: 1.0).faults == 0)

    detector.reset()
    for reporte in flujoRegular(intervalo: 0.008, cantidad: 100, desde: 10.0) {
        detector.record(reporte)
    }
    #expect(detector.health(now: 11.0).faults == 0, "el reinicio no debe inventar fallos")
}

@Test("Una marca de tiempo fuera de orden no crea un fallo fantasma")
func marcaFueraDeOrdenNoCreaFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    // Calibrar primero, para que la prueba ejercite de verdad la guarda de
    // orden y no pase solo porque el detector aún no juzga nada.
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 30) {
        detector.record(reporte)
    }
    detector.record(PointerReport(timestamp: 1.0, moved: true))
    // Llega un reporte atrasado: debe ignorarse sin mover la referencia.
    detector.record(PointerReport(timestamp: 0.9, moved: true))
    detector.record(PointerReport(timestamp: 1.001, moved: true))
    #expect(detector.health(now: 1.1).faults == 0)
}
