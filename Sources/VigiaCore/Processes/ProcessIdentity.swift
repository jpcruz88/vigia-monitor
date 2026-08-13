import Foundation

/// Traduce la ruta de un ejecutable al nombre de aplicación que el usuario
/// reconoce, y a una clave para agrupar procesos hermanos.
///
/// Hace falta porque la lista cruda del sistema es ilegible: un navegador
/// abierto aparece como veinte procesos —uno por pestaña, más los de red, GPU
/// y utilidades— y ninguno se llama como la aplicación. Ofrecerle al usuario
/// "cerrar Google Chrome Helper (Renderer)" no le sirve de nada: lo que quiere
/// cerrar es Chrome.
///
/// La regla es la anidación de los paquetes. Un ayudante vive dentro del
/// paquete de su aplicación:
///
///     /Applications/Google Chrome.app/Contents/Frameworks/…
///         /Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper
///
/// El **primer** `.app` de la ruta es la aplicación de verdad; los demás son
/// ayudantes suyos. Tomar el último daría justo el nombre inútil.
public enum ProcessIdentity {
    /// Nombre legible del ejecutable en `path`.
    ///
    /// Devuelve el nombre de la aplicación contenedora si la hay, y si no el
    /// del propio binario. Nunca devuelve cadena vacía: sin nada mejor,
    /// prefiere la ruta entera a no decir nada.
    public static func displayName(forExecutablePath path: String) -> String {
        if let app = enclosingAppName(in: path) { return app }
        let ultimo = (path as NSString).lastPathComponent
        return ultimo.isEmpty ? path : ultimo
    }

    /// Clave por la que se agrupan los procesos de una misma aplicación.
    ///
    /// Es la ruta del paquete, no el nombre: dos aplicaciones distintas pueden
    /// llamarse igual —una en `/Applications` y otra descargada— y fundirlas en
    /// una sola fila haría que cerrar una cerrara la otra.
    public static func groupKey(forExecutablePath path: String) -> String {
        enclosingAppPath(in: path) ?? path
    }

    /// `true` si `path` es el binario principal de su aplicación, y no uno de
    /// sus ayudantes. Sirve para elegir a quién mandarle la señal de cierre.
    public static func isMainExecutable(ofApp path: String) -> Bool {
        guard let paquete = enclosingAppPath(in: path) else { return true }
        return path.hasPrefix(paquete + "/Contents/MacOS/")
    }

    /// Ruta del primer paquete `.app` que contiene a `path`.
    private static func enclosingAppPath(in path: String) -> String? {
        var acumulada = ""
        for componente in (path as NSString).pathComponents {
            // El primer componente de una ruta absoluta es "/", y unirlo con
            // otra barra daría "//Applications".
            acumulada = acumulada.isEmpty || acumulada == "/"
                ? acumulada + componente
                : acumulada + "/" + componente
            if componente.hasSuffix(".app") { return acumulada }
        }
        return nil
    }

    private static func enclosingAppName(in path: String) -> String? {
        guard let paquete = enclosingAppPath(in: path) else { return nil }
        let nombre = (paquete as NSString).lastPathComponent
        return String(nombre.dropLast(".app".count))
    }
}
