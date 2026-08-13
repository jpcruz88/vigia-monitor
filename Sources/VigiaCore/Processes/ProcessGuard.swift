import Foundation

/// Decide sobre qué procesos se puede actuar.
///
/// Vigía puede cerrar procesos, y eso la convierte en una herramienta capaz de
/// dejar el Mac inutilizable: cerrar `WindowServer` apaga la pantalla, cerrar
/// `Finder` se lleva el escritorio, y una señal a un demonio del sistema puede
/// dejar la sesión a medias. Nada de eso libera memoria de forma útil —el
/// sistema los relanza— así que no hay ninguna razón para permitirlo.
///
/// La política es de lista blanca por ubicación: se puede actuar sobre lo que
/// vive donde el usuario instala cosas, y no sobre lo que vive donde el sistema
/// instala las suyas. Es más restrictiva que enumerar procesos peligrosos por
/// nombre, y a diferencia de esa lista no se queda obsoleta con cada versión de
/// macOS.
public enum ProcessGuard {
    /// Prefijos de ruta que pertenecen al sistema operativo.
    ///
    /// `/Library` no está: ahí viven cosas de terceros que el usuario sí querrá
    /// poder cerrar. `/System/Library` sí, y es lo que cubre el primer prefijo.
    private static let systemPrefixes = [
        "/System/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/Library/Apple/"
    ]

    /// Procesos intocables aunque vivan fuera del sistema.
    ///
    /// Son los que sostienen la sesión gráfica. Cerrar cualquiera de ellos no
    /// es un error recuperable con un par de clics.
    private static let criticalNames: Set<String> = [
        "Finder",
        "Dock",
        "WindowServer",
        "loginwindow",
        "SystemUIServer",
        "ControlCenter",
        "NotificationCenter",
        "launchd",
        "kernel_task",
        "coreaudiod",
        "Vigía",
        "Vigia"
    ]

    /// `true` si Vigía debe negarse a mandarle señales a este proceso.
    ///
    /// - Parameters:
    ///   - path: ruta del ejecutable.
    ///   - pid: su identificador, para no dejar que la app se cierre a sí misma.
    ///   - selfPID: el identificador de esta misma app.
    public static func isProtected(
        path: String,
        pid: Int32,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        if pid == selfPID { return true }
        // Un pid inválido no identifica a nadie, y `kill(0, …)` se lo manda al
        // grupo entero de procesos: justo el accidente que esto debe evitar.
        if pid <= 1 { return true }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        return criticalNames.contains(ProcessIdentity.displayName(forExecutablePath: path))
    }
}
