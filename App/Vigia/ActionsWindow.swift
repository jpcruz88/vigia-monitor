import AppKit
import SwiftUI

/// La ventana de acciones, creada la primera vez que se pide.
///
/// Es una ventana normal, no un `NSPanel` como el HUD: aquí sí queremos que
/// tome el foco —hay botones que confirman cierres— y que aparezca en el
/// selector de ventanas. Se guarda una sola instancia para que abrirla dos
/// veces traiga la que ya existe en vez de duplicar el muestreo.
@MainActor
final class ActionsWindowController {
    private var window: NSWindow?
    private let model = ActionsModel()

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        ventana.title = "Vigía · Acciones"
        ventana.contentView = NSHostingView(rootView: ActionsView(model: model))
        ventana.center()
        // La app corre sin icono en el Dock, así que sin esto la ventana
        // aparecería detrás de lo que el usuario tuviera delante.
        ventana.isReleasedWhenClosed = false

        window = ventana
        ventana.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
