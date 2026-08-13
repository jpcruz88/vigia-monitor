import Foundation

/// Ejecuta `purge`, el comando que vacía la caché de disco del sistema.
///
/// **Esto casi nunca ayuda, y a menudo perjudica.** Está aquí porque se pidió
/// explícitamente, no porque se recomiende. Lo que hace `purge` es tirar la
/// caché de archivos que macOS mantiene en la memoria que nadie más está
/// usando. El efecto visible es que el número de "memoria libre" sube; el
/// efecto real es que las siguientes lecturas de esos archivos van al disco en
/// vez de a la memoria, y que la caché se vuelve a llenar en segundos.
///
/// La memoria libre cercana a cero no es un problema que arreglar: es el diseño
/// funcionando. Si el Mac va lento por memoria, el indicador que importa es la
/// presión y el swap, y el remedio es cerrar al proceso que se la come.
///
/// Por eso `run` devuelve la medición de antes y después: para que el usuario
/// compruebe el efecto en su propia máquina en vez de creerse el número que
/// suba.
public struct MemoryPurge: Sendable {
    /// Qué cambió realmente al purgar.
    public struct Outcome: Sendable, Equatable {
        public let freeBefore: UInt64
        public let freeAfter: UInt64
        /// Caché de archivos que se descartó. Es el coste, no el beneficio:
        /// todo esto habrá que releerlo del disco.
        public let cacheDropped: UInt64
        public let duration: TimeInterval
    }

    public enum Failure: Error, Equatable {
        /// El usuario canceló el diálogo de autenticación.
        case cancelled
        /// `purge` corrió pero falló.
        case failed(status: Int32)
        case unavailable
    }

    private static let executable = "/usr/sbin/purge"

    public init() {}

    /// Purga la caché tras pedir autorización de administrador.
    ///
    /// `purge` solo corre como root, así que esto abre el diálogo de
    /// autenticación de macOS. Se usa `osascript` porque las APIs de
    /// autorización de Security.framework están obsoletas desde macOS 10.7 y no
    /// tienen sustituto para lanzar un ejecutable con privilegios.
    ///
    /// Es una llamada bloqueante y puede tardar varios segundos.
    public func run(sampler: MemorySampler = MemorySampler()) throws -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw Failure.unavailable
        }

        let antes = try? sampler.sample()
        let inicio = Date()
        try ejecutarConPrivilegios()
        let duracion = Date().timeIntervalSince(inicio)
        let despues = try? sampler.sample()

        let libreAntes = antes?.freeBytes ?? 0
        let libreDespues = despues?.freeBytes ?? 0
        // La caché descartada se mide por lo que perdió el sistema, no por lo
        // que ganó "libre": parte de lo liberado se recupera al instante.
        let cacheAntes = (antes?.inactiveBytes ?? 0) + (antes?.speculativeBytes ?? 0)
        let cacheDespues = (despues?.inactiveBytes ?? 0) + (despues?.speculativeBytes ?? 0)

        return Outcome(
            freeBefore: libreAntes,
            freeAfter: libreDespues,
            cacheDropped: cacheAntes > cacheDespues ? cacheAntes - cacheDespues : 0,
            duration: duracion
        )
    }

    private func ejecutarConPrivilegios() throws {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proceso.arguments = [
            "-e",
            "do shell script \"\(Self.executable)\" with administrator privileges"
        ]
        let error = Pipe()
        proceso.standardError = error
        proceso.standardOutput = Pipe()

        try proceso.run()
        // Hay que leer antes de esperar: si `osascript` llenara el búfer de la
        // tubería se quedaría bloqueado escribiendo y nunca terminaría.
        let salida = error.fileHandleForReading.readDataToEndOfFile()
        proceso.waitUntilExit()

        guard proceso.terminationStatus != 0 else { return }

        // Cancelar el diálogo no es un fallo del que haya que informar como
        // error: el usuario decidió que no.
        let texto = String(decoding: salida, as: UTF8.self)
        if texto.contains("-128") || texto.localizedCaseInsensitiveContains("User canceled") {
            throw Failure.cancelled
        }
        throw Failure.failed(status: proceso.terminationStatus)
    }
}
