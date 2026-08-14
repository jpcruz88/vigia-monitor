import AppKit
import VigiaCore

/// Construye y atiende el menú contextual del panel.
///
/// Es un `NSMenu` de AppKit y no un `.contextMenu` de SwiftUI por una razón
/// concreta: el panel republica sus métricas cada segundo, así que SwiftUI
/// reconstruye la vista —y con ella el menú adosado— a ese mismo ritmo. Un menú
/// abierto se cerraba solo antes de que diera tiempo a entrar en un submenú.
///
/// Un `NSMenu` no depende del ciclo de redibujado: mientras está desplegado,
/// AppKit toma el control del bucle de eventos y el menú sobrevive a cualquier
/// actualización del panel que ocurra por debajo.
@MainActor
final class HUDMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    /// `unowned` porque el modelo es dueño de este controlador a través del
    /// panel: una referencia fuerte de vuelta cerraría el ciclo.
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
        menu.addItem(submenu("Mostrar", construir: metricas))
        menu.addItem(submenu("Tema", construir: temas))
        menu.addItem(submenu("Claro u oscuro", construir: apariencia))
        menu.addItem(submenu("Opacidad", construir: opacidades))

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

    private func temas(_ sub: NSMenu) {
        for tema in Theme.all {
            let entrada = item(tema.name, #selector(elegirTema))
            entrada.representedObject = tema.id
            entrada.state = settings.themeID == tema.id ? .on : .off
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

    private func opacidades(_ sub: NSMenu) {
        for valor in [1.0, 0.95, 0.8, 0.6] {
            let entrada = item("\(Int(valor * 100)) %", #selector(elegirOpacidad))
            entrada.representedObject = valor
            // Comparar decimales con `==` funciona aquí porque los valores
            // guardados vienen de esta misma lista, sin ninguna operación por
            // medio que pudiera introducir error.
            entrada.state = settings.opacity == valor ? .on : .off
            sub.addItem(entrada)
        }
    }

    // MARK: - Acciones

    @objc private func abrirAcciones() { model.showActions() }

    @objc private func alternarMetrica(_ sender: NSMenuItem) {
        guard let bruto = sender.representedObject as? String,
              let metrica = MetricKind(rawValue: bruto) else { return }
        settings.toggle(metrica)
    }

    @objc private func elegirTema(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.themeID = id
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

    @objc private func elegirOpacidad(_ sender: NSMenuItem) {
        guard let valor = sender.representedObject as? Double else { return }
        settings.opacity = valor
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
