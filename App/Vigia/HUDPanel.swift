import AppKit
import SwiftUI

/// Panel que flota sobre las demás ventanas sin robar el foco.
final class HUDPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 250, height: 220),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Flota por encima del resto de ventanas.
        level = .floating
        // Sigue visible al cambiar de espacio y con apps en pantalla completa.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // No debe esconderse cuando el usuario cambia de aplicación: el panel
        // solo sirve si está siempre a la vista.
        hidesOnDeactivate = false
        isFloatingPanel = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let anfitrion = NSHostingView(rootView: content)
        contentView = anfitrion
        setContentSize(anfitrion.fittingSize)
    }

    // Un panel de utilidad no debe convertirse en la ventana clave ni
    // principal: si lo hiciera, robaría el foco al hacer clic en él.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
