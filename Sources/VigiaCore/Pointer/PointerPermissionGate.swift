import Foundation

/// Decide qué puede hacer la aplicación con el permiso de Monitoreo de Entrada.
///
/// Existe por una regla de macOS que no es evidente y que cuesta cara si se
/// ignora: **conceder el permiso no se lo aplica a un proceso que ya está
/// corriendo.** Lo afirma el propio panel de Ajustes del Sistema al activar el
/// interruptor de una app en marcha —"no podrá monitorizar la entrada hasta
/// que salgas de la app"—, y es coherente con cómo se resuelve TCC: una vez
/// por proceso, al primer contacto.
///
/// La trampa está en que `IOHIDCheckAccess` **sí** empieza a responder
/// `granted` en ese mismo instante. Un reintento en caliente parece funcionar
/// —arranca sin error, no hay nada que registrar como fallo— y deja la app
/// midiendo un flujo que nunca llega: "sin señal" para siempre, sin explicar
/// por qué. Es el mismo patrón que `IOHIDManagerOpen`, que también devuelve
/// éxito sin permiso.
///
/// Por eso este tipo no reintenta: al detectar el permiso concedido después
/// del arranque pasa a `needsRestart`, y reiniciar es cosa de la interfaz.
public struct PointerPermissionGate: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        /// Hay permiso desde el arranque y el monitor está midiendo.
        case measuring
        /// Falta el permiso. Hay que llevar al usuario a Ajustes del Sistema.
        case needsGrant
        /// El permiso ya está concedido, pero llegó después de arrancar este
        /// proceso, así que no recibirá ni un solo evento hasta reiniciarse.
        case needsRestart
    }

    public private(set) var stage: Stage

    /// - Parameter started: si `PointerHealthMonitor.start()` tuvo éxito.
    public init(started: Bool) {
        stage = started ? .measuring : .needsGrant
    }

    /// Reevalúa con el permiso actual; pensado para llamarse periódicamente
    /// mientras la app espera a que el usuario conceda el acceso.
    ///
    /// Solo avanza desde `needsGrant`. Los otros dos estados son terminales
    /// para este proceso: `measuring` ya tiene acceso —y lo conserva aunque el
    /// usuario revoque el permiso, porque macOS tampoco aplica la revocación en
    /// caliente— y `needsRestart` no puede resolverse sin un proceso nuevo.
    public mutating func refresh(access: PointerHealthMonitor.Access) {
        guard stage == .needsGrant, access == .granted else { return }
        stage = .needsRestart
    }
}
