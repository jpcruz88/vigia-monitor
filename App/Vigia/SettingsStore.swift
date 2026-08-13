import Foundation
import ServiceManagement

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

    init() {
        let guardada = UserDefaults.standard.double(forKey: "hud.opacity")
        // Cero significa que nunca se ha guardado nada.
        opacity = guardada == 0 ? 0.95 : guardada
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let ocultas = UserDefaults.standard.stringArray(forKey: "hud.hidden") ?? []
        hidden = Set(ocultas.compactMap(MetricKind.init(rawValue:)))
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
