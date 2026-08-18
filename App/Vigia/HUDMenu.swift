import AppKit
import VigiaCore

/// Construye y atiende el menú del ítem de la barra.
///
/// Se reconstruye cada vez que se despliega, así que las palomitas y los
/// avisos del mouse siempre reflejan el estado actual sin observar nada.
@MainActor
final class HUDMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    /// `unowned` porque el delegado de la app es dueño del modelo y de este
    /// controlador: una referencia fuerte de vuelta cerraría el ciclo.
    private unowned let model: HUDModel
    private var settings: SettingsStore { model.settings }

    /// Franjas horarias ofrecidas. Configurar horas exactas pediría una ventana
    /// de ajustes que esta app no tiene; tres presets cubren el caso real.
    private let horarios: [(claro: Int, oscuro: Int)] = [
        (claro: 6, oscuro: 18),
        (claro: 7, oscuro: 19),
        (claro: 8, oscuro: 20)
    ]

    init(model: HUDModel) {
        self.model = model
        super.init()
        menu.delegate = self
    }

    /// AppKit lo llama justo antes de desplegar el menú. Reconstruirlo aquí es
    /// lo que mantiene las palomitas al día sin tener que observar los ajustes.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(item("Ver consumo y actuar…", #selector(abrirAcciones)))
        menu.addItem(.separator())

        // Sin ventana propia, el permiso del mouse solo se puede pedir desde
        // aquí. macOS solo entrega eventos HID a un proceso arrancado ya con
        // el permiso, así que tras concederlo hace falta reiniciar.
        switch model.pointerStage {
        case .needsGrant:
            menu.addItem(item("Activar detección de trabones…", #selector(pedirPermiso)))
            menu.addItem(.separator())
        case .needsRestart:
            menu.addItem(item("Reiniciar para medir el mouse", #selector(reiniciar)))
            menu.addItem(.separator())
        case .measuring:
            break
        }

        menu.addItem(submenu("Mostrar", construir: metricas))
        menu.addItem(submenu("Claro u oscuro", construir: apariencia))

        let arranque = item("Arrancar con el sistema", #selector(alternarArranque))
        arranque.state = settings.launchAtLogin ? .on : .off
        menu.addItem(arranque)

        menu.addItem(.separator())
        menu.addItem(item("Acerca de Vigía…", #selector(acercaDe)))
        menu.addItem(item(About.developer, #selector(abrirSitio)))
        menu.addItem(.separator())
        menu.addItem(item("Salir de Vigía", #selector(salir)))
    }

    // MARK: - Submenús

    private func metricas(_ sub: NSMenu) {
        for metrica in MetricKind.allCases {
            let entrada = item(metrica.label, #selector(alternarMetrica))
            entrada.representedObject = metrica.rawValue
            entrada.state = settings.isVisible(metrica) ? .on : .off
            sub.addItem(entrada)
        }
    }

    private func apariencia(_ sub: NSMenu) {
        for modo in AppearanceMode.allCases {
            let entrada = item(modo.label, #selector(elegirModo))
            entrada.representedObject = modo.rawValue
            entrada.state = settings.appearance == modo ? .on : .off
            sub.addItem(entrada)
        }

        // Las franjas solo tienen sentido si el horario manda; mostrarlas
        // siempre invitaría a ajustar algo que no se está usando.
        guard settings.appearance == .schedule else { return }
        sub.addItem(.separator())
        for horario in horarios {
            let entrada = item(
                "Claro de \(horario.claro):00 a \(horario.oscuro):00",
                #selector(elegirHorario)
            )
            entrada.representedObject = horario.claro
            entrada.state = settings.schedule.lightStartMinutes == horario.claro * 60
                && settings.schedule.darkStartMinutes == horario.oscuro * 60 ? .on : .off
            sub.addItem(entrada)
        }
    }

    // MARK: - Acciones

    @objc private func abrirAcciones() { model.showActions() }

    @objc private func pedirPermiso() { model.openInputMonitoringSettings() }

    @objc private func reiniciar() { model.restartApp() }

    @objc private func alternarMetrica(_ sender: NSMenuItem) {
        guard let bruto = sender.representedObject as? String,
              let metrica = MetricKind(rawValue: bruto) else { return }
        settings.toggle(metrica)
    }

    @objc private func elegirModo(_ sender: NSMenuItem) {
        guard let bruto = sender.representedObject as? String,
              let modo = AppearanceMode(rawValue: bruto) else { return }
        settings.appearance = modo
    }

    @objc private func elegirHorario(_ sender: NSMenuItem) {
        guard let claro = sender.representedObject as? Int,
              let horario = horarios.first(where: { $0.claro == claro }) else { return }
        settings.schedule = AppearanceSchedule(
            lightStartMinutes: horario.claro * 60,
            darkStartMinutes: horario.oscuro * 60
        )
    }

    @objc private func alternarArranque() {
        settings.launchAtLogin.toggle()
    }

    @objc private func acercaDe() { About.showPanel() }

    @objc private func abrirSitio() { About.openSite() }

    @objc private func salir() { NSApplication.shared.terminate(nil) }

    // MARK: - Construcción

    private func item(_ titulo: String, _ accion: Selector) -> NSMenuItem {
        let entrada = NSMenuItem(title: titulo, action: accion, keyEquivalent: "")
        // Sin destino explícito, AppKit buscaría el selector por la cadena de
        // respondedores, y este controlador no está en ella.
        entrada.target = self
        return entrada
    }

    private func submenu(_ titulo: String, construir: (NSMenu) -> Void) -> NSMenuItem {
        let entrada = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        construir(sub)
        entrada.submenu = sub
        return entrada
    }
}
