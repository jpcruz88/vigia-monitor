import AppKit

/// La autoría de la aplicación y la página a la que enlaza.
///
/// Está en un solo sitio porque aparece en tres: el panel "Acerca de", el pie
/// de la ventana de acciones y el copyright del paquete. Repetir la dirección
/// en cada uno garantizaría que algún día dejaran de coincidir.
enum About {
    static let developer = "jpsoftware.dev"
    static let url = URL(string: "https://jpsoftware.dev")!

    static let credit = "Desarrollado por \(developer)"

    /// Muestra el panel estándar de macOS con el crédito enlazado.
    ///
    /// Se usa el panel del sistema en vez de una ventana propia porque ya trae
    /// el nombre, el icono y la versión del paquete, y porque es donde el
    /// usuario espera encontrar esto en cualquier aplicación de Mac.
    @MainActor
    static func showPanel() {
        let creditos = NSMutableAttributedString(string: credit)
        // El rango se busca en vez de escribirse a mano: un cambio en el texto
        // dejaría un desplazamiento fijo enlazando la palabra equivocada.
        if let rango = credit.range(of: developer) {
            creditos.addAttribute(.link, value: url, range: NSRange(rango, in: credit))
        }
        creditos.addAttributes(
            [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)],
            range: NSRange(location: 0, length: creditos.length)
        )

        NSApp.orderFrontStandardAboutPanel(options: [.credits: creditos])
        // La app corre sin icono en el Dock, así que sin esto el panel se
        // abriría detrás de lo que el usuario tuviera delante.
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    static func openSite() {
        NSWorkspace.shared.open(url)
    }
}
