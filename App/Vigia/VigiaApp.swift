import SwiftUI
import AppKit

@main
struct VigiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Toda la interfaz vive en la barra de menús, no en una escena de
        // SwiftUI. Esta escena existe solo porque `App` exige alguna.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = HUDModel()
    private var statusBar: StatusBarController?
    /// Se guarda porque `NSMenu` no retiene a su delegado.
    private var menuController: HUDMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuController = HUDMenuController(model: model)
        self.menuController = menuController
        statusBar = StatusBarController(model: model, menu: menuController.menu)
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
        // Obligatorio: los callbacks de IOKit guardan un puntero sin dueño al
        // monitor del mouse.
        model.stop()
    }
}
