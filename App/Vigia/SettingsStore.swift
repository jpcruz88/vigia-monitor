import Foundation
import ServiceManagement
import VigiaCore

/// Las métricas que el panel puede mostrar u ocultar.
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, pointer, keyboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memoria"
        case .gpu: return "GPU"
        case .disk: return "Disco"
        case .pointer: return "Mouse"
        case .keyboard: return "Teclado"
        }
    }
}

/// Ajustes que sobreviven al reinicio.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "hud.opacity") }
    }
    @Published var launchAtLogin: Bool {
        didSet { aplicarArranque() }
    }
    /// Se guardan las métricas **ocultas**, no las visibles, para que una
    /// métrica nueva en una versión futura aparezca por omisión en vez de
    /// quedar invisible sin que nadie sepa por qué.
    @Published var hidden: Set<MetricKind> {
        didSet {
            UserDefaults.standard.set(hidden.map(\.rawValue), forKey: "hud.hidden")
        }
    }

    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "hud.theme") }
    }
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "hud.appearance")
            actualizarHorario()
        }
    }
    @Published var schedule: AppearanceSchedule {
        didSet {
            UserDefaults.standard.set(schedule.lightStartMinutes, forKey: "hud.lightStart")
            UserDefaults.standard.set(schedule.darkStartMinutes, forKey: "hud.darkStart")
            actualizarHorario()
        }
    }

    /// Lo que dice el horario ahora mismo. Se recalcula con un reloj porque
    /// nada más avisa de que pasó la hora: sin él, el panel se quedaría con el
    /// color del momento en que se abrió hasta que algo lo redibujara.
    @Published private(set) var scheduleSaysDark = false

    var theme: Theme { Theme.named(themeID) }

    private var reloj: Task<Void, Never>?

    init() {
        let guardada = UserDefaults.standard.double(forKey: "hud.opacity")
        // Cero significa que nunca se ha guardado nada.
        opacity = guardada == 0 ? 0.95 : guardada
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let ocultas = UserDefaults.standard.stringArray(forKey: "hud.hidden") ?? []
        hidden = Set(ocultas.compactMap(MetricKind.init(rawValue:)))

        themeID = UserDefaults.standard.string(forKey: "hud.theme") ?? Theme.sistema.id
        appearance = UserDefaults.standard.string(forKey: "hud.appearance")
            .flatMap(AppearanceMode.init(rawValue:)) ?? .system

        let claro = UserDefaults.standard.object(forKey: "hud.lightStart") as? Int
        let oscuro = UserDefaults.standard.object(forKey: "hud.darkStart") as? Int
        schedule = AppearanceSchedule(
            lightStartMinutes: claro ?? AppearanceSchedule.default.lightStartMinutes,
            darkStartMinutes: oscuro ?? AppearanceSchedule.default.darkStartMinutes
        )

        actualizarHorario()
        arrancarReloj()
    }

    deinit { reloj?.cancel() }

    /// Decide el aspecto final combinando el ajuste con lo que dice macOS.
    ///
    /// - Parameter systemDark: si el sistema está en oscuro. Lo aporta la vista,
    ///   que es quien lo recibe del entorno.
    func isDark(systemDark: Bool) -> Bool {
        switch appearance {
        case .system: return systemDark
        case .light: return false
        case .dark: return true
        case .schedule: return scheduleSaysDark
        }
    }

    private func actualizarHorario() {
        let ahora = schedule.isDark(at: Date())
        // Publicar solo el cambio: asignar lo mismo redibujaría el panel cada
        // minuto sin motivo.
        if ahora != scheduleSaysDark { scheduleSaysDark = ahora }
    }

    /// Comprueba la hora cada minuto. Es la resolución del propio horario, así
    /// que el retraso máximo es de un minuto y el coste, inapreciable.
    private func arrancarReloj() {
        reloj = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.actualizarHorario()
            }
        }
    }

    func isVisible(_ metrica: MetricKind) -> Bool {
        !hidden.contains(metrica)
    }

    func toggle(_ metrica: MetricKind) {
        if hidden.contains(metrica) {
            hidden.remove(metrica)
        } else {
            hidden.insert(metrica)
        }
    }

    private func aplicarArranque() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Si el sistema lo rechaza, la casilla debe reflejar el estado
            // real y no la intención del usuario.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
