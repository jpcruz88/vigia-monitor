import SwiftUI
import AppKit

@main
struct VigiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // La interfaz vive en un NSPanel, no en una escena de SwiftUI: una
        // ventana normal no puede flotar sobre las demás sin robar el foco.
        // Esta escena existe solo porque `App` exige alguna.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: HUDPanel?
    private let model = HUDModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = HUDPanel(content: HUDView(model: model))
        panel.colocar(en: model.savedOrigin)
        panel.orderFrontRegardless()
        self.panel = panel
        model.start()

        // Al despertar hay que descartar los contadores que se calculan por
        // diferencia; si no, la primera lectura tras dormir da un pico falso.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.handleWake() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let origen = panel?.frame.origin {
            model.saveOrigin(origen)
        }
        // Obligatorio: los callbacks de IOKit guardan un puntero sin dueño al
        // monitor del mouse.
        model.stop()
    }

    // Sin icono en el Dock no hay nada que reabrir, pero si el usuario relanza
    // la app conviene traer el panel al frente en vez de no hacer nada.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }
}
