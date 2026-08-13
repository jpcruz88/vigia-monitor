import Foundation
import Darwin

/// Ejecuta las acciones correctivas sobre un proceso.
///
/// Todo lo de aquí es irreversible desde el punto de vista del usuario: un
/// proceso cerrado se lleva lo que no hubiera guardado. Por eso cada método
/// vuelve a consultar a `ProcessGuard` en vez de fiarse de lo que la interfaz
/// creyera al dibujar la lista. Esa lista puede tener segundos de antigüedad, y
/// en ese hueco el pid pudo quedar libre y reasignarse a otro proceso.
public enum ProcessActions {
    public enum Failure: Error, Equatable {
        /// El proceso está protegido: del sistema, o Vigía misma.
        case protected
        /// Ya no existe. Casi siempre es inocuo: terminó por su cuenta.
        case noSuchProcess
        /// Sin permiso. Pertenece a otro usuario o está bajo protección de
        /// integridad del sistema.
        case notPermitted
        /// La prioridad pedida está fuera del rango que acepta el sistema.
        case invalidPriority
        case unknown(code: Int32)
    }

    /// Rango de prioridad que se le ofrece al usuario.
    ///
    /// Solo hacia abajo. Subir prioridad exige privilegios de root y, sobre
    /// todo, no arregla nada: quitarle sitio al resto del sistema para dárselo
    /// a un proceso que ya iba sobrado empeora justo lo que se quería mejorar.
    public static let priorityRange = 0...20

    /// Le pide al proceso que se cierre él mismo (`SIGTERM`).
    ///
    /// Es lo que debe intentarse primero: una aplicación que recibe `SIGTERM`
    /// puede guardar, preguntar y cerrar en orden. No hay garantía de que
    /// obedezca, ni de que lo haga rápido.
    public static func requestQuit(pid: Int32, path: String) throws(Failure) {
        try enviar(SIGTERM, a: pid, ruta: path)
    }

    /// Lo mata sin avisar (`SIGKILL`).
    ///
    /// El proceso no puede interceptar esta señal, así que no guarda nada ni
    /// cierra archivos en orden. Solo tiene sentido después de que `SIGTERM`
    /// fallara, y con el usuario sabiendo que perderá lo no guardado.
    public static func forceQuit(pid: Int32, path: String) throws(Failure) {
        try enviar(SIGKILL, a: pid, ruta: path)
    }

    /// Baja la prioridad del proceso sin cerrarlo.
    ///
    /// La alternativa amable a cerrar algo: una compilación o una exportación
    /// siguen su curso, pero dejan de disputarle la CPU a lo que tienes
    /// delante. `nice` es un número donde **más alto es menos prioritario**.
    ///
    /// - Note: solo afecta a la CPU. Un proceso que satura el disco o la red
    ///   seguirá haciéndolo igual.
    public static func lowerPriority(pid: Int32, path: String, to nice: Int32) throws(Failure) {
        guard priorityRange.contains(Int(nice)) else { throw .invalidPriority }
        guard !ProcessGuard.isProtected(path: path, pid: pid) else { throw .protected }

        // `setpriority` devuelve -1 tanto al fallar como, legítimamente, al no
        // fallar en algunas plataformas; `errno` es lo único de fiar, y hay que
        // limpiarlo antes porque conserva el error de cualquier llamada previa.
        errno = 0
        guard setpriority(PRIO_PROCESS, UInt32(pid), nice) == 0 || errno == 0 else {
            throw traducir(errno)
        }
    }

    /// Prioridad actual, o `nil` si no se puede consultar.
    public static func currentPriority(pid: Int32) -> Int32? {
        errno = 0
        let valor = getpriority(PRIO_PROCESS, UInt32(pid))
        // -1 es una prioridad válida, así que solo `errno` distingue el fallo.
        guard errno == 0 else { return nil }
        return valor
    }

    private static func enviar(_ señal: Int32, a pid: Int32, ruta: String) throws(Failure) {
        guard !ProcessGuard.isProtected(path: ruta, pid: pid) else { throw .protected }
        guard kill(pid, señal) == 0 else { throw traducir(errno) }
    }

    private static func traducir(_ code: Int32) -> Failure {
        switch code {
        case ESRCH: return .noSuchProcess
        case EPERM: return .notPermitted
        case EINVAL: return .invalidPriority
        default: return .unknown(code: code)
        }
    }
}
