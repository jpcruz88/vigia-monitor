import AppKit
import Combine
import VigiaCore

/// El ítem de la barra de menús: toda la interfaz de Vigía.
///
/// Las métricas se pintan directamente en el título del ítem, en vivo, y un
/// clic (izquierdo o derecho, da igual) despliega el menú. No hay panel ni
/// popover: lo que hay que ver está siempre a la vista, arriba, y lo que hay
/// que hacer está a un clic.
@MainActor
final class StatusBarController {
    /// Por debajo de este porcentaje la batería sale a la barra. Por encima no
    /// dice nada accionable —un teclado BLE marca 100 % durante semanas— y solo
    /// alarga el título. El valor exacto está siempre en el menú.
    static let bateriaBaja = 20

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: HUDModel
    private var suscripciones: Set<AnyCancellable> = []

    init(model: HUDModel, menu: NSMenu) {
        self.model = model
        item.menu = menu
        if let boton = item.button {
            boton.imagePosition = .imageLeading
            boton.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent",
                                  accessibilityDescription: "Vigía")
            boton.image?.isTemplate = true
        }

        actualizarTitulo()
        // Redibujar con cada snapshot; los ajustes cambian qué métricas se
        // muestran, así que también hay que escucharlos.
        model.$snapshot
            .sink { [weak self] _ in self?.actualizarTitulo() }
            .store(in: &suscripciones)
        model.settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.actualizarTitulo() }
            .store(in: &suscripciones)
    }

    /// Un resumen de lo visible: "CPU 23%  Memoria 61%  GPU 4%  Disco 73%  Mouse estable".
    /// Solo aparecen las métricas activas en "Mostrar", así que la barra se
    /// puede dejar tan escueta como se quiera. Las baterías solo se suman
    /// cuando están bajas: ver "Teclado 100 %" todos los días entrena a
    /// ignorarlo justo para el día en que diga otra cosa.
    private func actualizarTitulo() {
        let s = model.snapshot
        let ajustes = model.settings
        var partes: [String] = []

        func agregar(_ etiqueta: String, _ fraccion: Double?) {
            let cifra = fraccion.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            partes.append("\(etiqueta) \(cifra)")
        }

        if ajustes.isVisible(.cpu) { agregar("CPU", s.cpu.value?.totalUsage) }
        if ajustes.isVisible(.memory) { agregar("Memoria", s.memory.value?.usedFraction) }
        if ajustes.isVisible(.gpu) { agregar("GPU", s.gpu.value?.utilization) }
        if ajustes.isVisible(.disk) { agregar("Disco", s.disk.value?.usedFraction) }
        if ajustes.isVisible(.pointer) {
            // La batería solo llega por Bluetooth; con receptor USB no existe.
            if let bateria = s.peripherals.value?.mouseBatteryPercent,
               bateria < Self.bateriaBaja {
                partes.append("Mouse \(textoDelMouse) · batería \(bateria)%")
            } else {
                partes.append("Mouse \(textoDelMouse)")
            }
        }
        if ajustes.isVisible(.keyboard),
           let bateria = s.peripherals.value?.keyboardBatteryPercent,
           bateria < Self.bateriaBaja {
            partes.append("Teclado batería \(bateria)%")
        }

        let texto = partes.joined(separator: "  ")
        let fuente = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.attributedTitle = NSAttributedString(
            string: texto.isEmpty ? "" : " " + texto,
            attributes: [.font: fuente]
        )
    }

    private var textoDelMouse: String {
        switch model.pointerStage {
        case .needsGrant: return "sin permiso"
        case .needsRestart: return "reiniciar"
        case .measuring: break
        }
        guard let salud = model.snapshot.pointer.value else { return "sin señal" }
        guard salud.faults > 0 else { return "estable" }
        return String(format: "%d fallos · %.0f ms", salud.faults, salud.maxFaultGapSeconds * 1000)
    }
}
