import Foundation
import Testing
@testable import VigiaCore

@Test("Con permiso desde el arranque, la compuerta mide y no se mueve de ahí")
func arranqueConPermisoMide() {
    var gate = PointerPermissionGate(started: true)
    #expect(gate.stage == .measuring)

    gate.refresh(access: .granted)
    #expect(gate.stage == .measuring)
}

@Test("Sin permiso, la compuerta pide concederlo")
func arranqueSinPermisoPideConcederlo() {
    var gate = PointerPermissionGate(started: false)
    #expect(gate.stage == .needsGrant)

    // Mientras el usuario no lo conceda, no hay nada nuevo que decirle.
    gate.refresh(access: .denied)
    #expect(gate.stage == .needsGrant)

    gate.refresh(access: .undetermined)
    #expect(gate.stage == .needsGrant)
}

/// La regresión que motivó este tipo. Antes se reintentaba `start()` en
/// caliente: arrancaba sin error, no llegaba ni un evento, y el panel decía
/// "sin señal" indefinidamente sin explicar por qué.
@Test("Conceder el permiso con la app corriendo exige reiniciar, no reintentar")
func permisoConcedidoEnCalienteExigeReinicio() {
    var gate = PointerPermissionGate(started: false)
    #expect(gate.stage == .needsGrant)

    gate.refresh(access: .granted)
    #expect(gate.stage == .needsRestart)
}

@Test("Pedido el reinicio, ninguna consulta posterior lo cancela")
func elReinicioNoSeCancelaSolo() {
    var gate = PointerPermissionGate(started: false)
    gate.refresh(access: .granted)
    #expect(gate.stage == .needsRestart)

    // Ni insistiendo con el permiso concedido...
    gate.refresh(access: .granted)
    #expect(gate.stage == .needsRestart)

    // ...ni si el usuario lo revoca mientras duda. Sigue haciendo falta un
    // proceso nuevo, y volver a `needsGrant` mandaría al usuario a Ajustes a
    // activar un interruptor que ya activó.
    gate.refresh(access: .denied)
    #expect(gate.stage == .needsRestart)
}
