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
        // Forzar el trazado antes de medir: sin esto `fittingSize` vale cero,
        // y un panel de 0 x 0 es invisible aunque `isVisible` responda que sí
        // y aunque no aparezca ningún error por ningún lado.
        anfitrion.layoutSubtreeIfNeeded()

        var tamano = anfitrion.fittingSize
        // Red de seguridad: si el trazado forzado tampoco bastara, un tamaño
        // fijo razonable es infinitamente mejor que un panel invisible.
        if tamano.width < 50 || tamano.height < 50 {
            tamano = NSSize(width: 250, height: 220)
        }
        setContentSize(tamano)
    }

    /// Coloca el panel en una esquina visible de la pantalla, respetando la
    /// posición guardada si sigue cayendo dentro de alguna pantalla conectada.
    /// Se llama después de que el contenido fijó el tamaño: antes, la altura
    /// todavía es cero y cualquier cálculo de posición sale mal.
    func colocar(en guardada: NSPoint?) {
        if let guardada, Self.esVisible(origen: guardada, tamano: frame.size) {
            setFrameOrigin(guardada)
            return
        }
        guard let pantalla = NSScreen.main else { return }
        let area = pantalla.visibleFrame
        let margen: CGFloat = 24
        setFrameOrigin(NSPoint(x: area.maxX - frame.width - margen,
                               y: area.maxY - frame.height - margen))
    }

    /// Una posición guardada deja de servir si el monitor donde estaba se
    /// desconectó: el panel quedaría fuera de toda pantalla y sería inalcanzable.
    private static func esVisible(origen: NSPoint, tamano: NSSize) -> Bool {
        let marco = NSRect(origin: origen, size: tamano)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(marco) }
    }

    // Un panel de utilidad no debe convertirse en la ventana clave ni
    // principal: si lo hiciera, robaría el foco al hacer clic en él.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
