import Foundation

/// Un sitio del que se puede recuperar espacio, y cuánto hay ahora mismo.
public struct CleanupTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Qué es y qué pasa al borrarlo, en los términos del usuario. La interfaz
    /// lo muestra antes de pedir confirmación: nadie debería aceptar un borrado
    /// sin saber qué pierde.
    public let explanation: String
    public let directory: URL
    public let reclaimableBytes: UInt64
    /// Número de elementos de primer nivel que se borrarían.
    public let itemCount: Int
}

/// Encuentra y borra espacio recuperable de verdad.
///
/// A diferencia de "liberar RAM", aquí sí hay algo que ganar: son archivos que
/// ocupan disco, que el sistema no va a borrar solo, y que se regeneran cuando
/// hagan falta. Aun así ninguno es gratis —borrar una caché hace que lo
/// siguiente se recalcule— así que cada objetivo lleva su explicación.
///
/// **Nunca borra el directorio, solo su contenido.** Varios de estos los crea
/// el sistema al arrancar y espera encontrarlos; borrar el contenedor deja a
/// alguna aplicación sin sitio donde escribir.
public struct DiskCleanup: Sendable {
    private let home: URL

    /// - Parameter home: la carpeta personal. Se inyecta para poder probar el
    ///   borrado contra un árbol de mentira: una prueba que se equivoque aquí
    ///   borra archivos de verdad.
    public init(home: URL? = nil) {
        self.home = home ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// `FileManager.default` es seguro para estas operaciones desde cualquier
    /// hilo; guardarlo como propiedad no lo sería, porque la clase no es
    /// `Sendable` y esta estructura sí necesita serlo.
    private var fileManager: FileManager { .default }

    /// Los sitios candidatos, existan o no todavía.
    private var candidatos: [(id: String, name: String, ruta: String, explicacion: String)] {
        [
            (
                "caches", "Cachés de aplicaciones", "Library/Caches",
                "Datos temporales que las aplicaciones recalculan cuando los "
                    + "necesiten. Borrarlos es seguro; algunas apps tardarán un poco "
                    + "más la primera vez que las abras."
            ),
            (
                "trash", "Papelera", ".Trash",
                "Lo que ya mandaste a la papelera. Al borrarlo aquí desaparece "
                    + "definitivamente."
            ),
            (
                "derived", "Compilaciones de Xcode", "Library/Developer/Xcode/DerivedData",
                "Resultados intermedios de compilar proyectos. Xcode los rehace "
                    + "solo; a cambio, la siguiente compilación de cada proyecto "
                    + "será completa y tardará más."
            ),
            (
                "archives", "Registros de dispositivos de Xcode",
                "Library/Developer/Xcode/iOS DeviceSupport",
                "Símbolos que Xcode copió de cada iPhone o iPad que conectaste, "
                    + "incluidas versiones de iOS que ya no usas. Se vuelven a "
                    + "copiar al conectar el dispositivo."
            )
        ]
    }

    /// Mide cuánto hay recuperable en cada sitio.
    ///
    /// Recorrer directorios grandes cuesta segundos, así que conviene llamarla
    /// fuera del hilo principal. Los sitios que no existen o están vacíos no
    /// aparecen en el resultado.
    public func scan() -> [CleanupTarget] {
        candidatos.compactMap { candidato in
            let url = home.appendingPathComponent(candidato.ruta)
            guard let hijos = try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ), !hijos.isEmpty else { return nil }

            let bytes = hijos.reduce(UInt64(0)) { $0 + tamaño(de: $1) }
            guard bytes > 0 else { return nil }

            return CleanupTarget(
                id: candidato.id,
                name: candidato.name,
                explanation: candidato.explicacion,
                directory: url,
                reclaimableBytes: bytes,
                itemCount: hijos.count
            )
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Borra el contenido de un objetivo y devuelve cuántos bytes se fueron.
    ///
    /// Sigue adelante cuando un elemento concreto falla: en `Library/Caches`
    /// siempre hay algo abierto por una aplicación en marcha, y abortar por eso
    /// dejaría el trabajo a medias sin recuperar casi nada.
    ///
    /// - Throws: `Failure.outsideHome` si el objetivo no cuelga de la carpeta
    ///   personal. Es la única salvaguarda real contra un borrado catastrófico,
    ///   así que se comprueba aquí y no en quien llama.
    @discardableResult
    public func purge(_ target: CleanupTarget) throws -> UInt64 {
        try validar(target.directory)

        var liberados: UInt64 = 0
        let hijos = (try? fileManager.contentsOfDirectory(
            at: target.directory, includingPropertiesForKeys: nil
        )) ?? []

        for hijo in hijos {
            let bytes = tamaño(de: hijo)
            // El tamaño se mide antes: después del borrado ya no hay nada que
            // medir, y contarlo solo si tuvo éxito evita inflar el total.
            if (try? fileManager.removeItem(at: hijo)) != nil { liberados += bytes }
        }
        return liberados
    }

    public enum Failure: Error, Equatable {
        /// El objetivo no está dentro de la carpeta personal del usuario.
        case outsideHome
    }

    /// Comprueba que la ruta cuelgue de la carpeta personal.
    ///
    /// Compara rutas ya resueltas: sin `standardized` un `..` de más colaría
    /// cualquier destino del disco tras un prefijo que sí parece correcto.
    private func validar(_ url: URL) throws {
        let destino = url.standardizedFileURL.path
        let raiz = home.standardizedFileURL.path
        guard destino.hasPrefix(raiz + "/") else { throw Failure.outsideHome }
    }

    /// Bytes que ocupa un archivo o, recursivamente, un directorio.
    private func tamaño(de url: URL) -> UInt64 {
        let claves: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]

        guard let valores = try? url.resourceValues(forKeys: Set(claves)) else { return 0 }
        if valores.isDirectory != true {
            // El tamaño *asignado* es el que se recupera al borrar: un archivo
            // disperso o comprimido ocupa menos de lo que dice su longitud.
            return UInt64(valores.totalFileAllocatedSize ?? valores.fileAllocatedSize ?? 0)
        }

        guard let recorrido = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: claves,
            // Sin esto el recorrido entra en cada paquete y en los enlaces
            // simbólicos, y un enlace circular no termina nunca.
            options: [.skipsPackageDescendants]
        ) else { return 0 }

        var total: UInt64 = 0
        for caso in recorrido {
            guard let hijo = caso as? URL,
                  let valores = try? hijo.resourceValues(forKeys: Set(claves)),
                  valores.isDirectory != true else { continue }
            total += UInt64(valores.totalFileAllocatedSize ?? valores.fileAllocatedSize ?? 0)
        }
        return total
    }
}
