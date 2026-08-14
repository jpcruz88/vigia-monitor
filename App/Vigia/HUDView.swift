import SwiftUI
import AppKit
import VigiaCore

/// Dibuja el snapshot. Sin lógica: si aquí aparece un cálculo, va en el motor.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject private var settings: SettingsStore

    init(model: HUDModel) {
        self.model = model
        self.settings = model.settings
    }

    /// Lo que macOS tiene puesto. Solo se usa cuando el ajuste es "seguir al
    /// sistema"; en los demás modos manda el ajuste.
    @Environment(\.colorScheme) private var colorScheme

    /// La paleta vigente. Todo color del panel sale de aquí.
    private var paleta: Palette {
        settings.theme.palette(dark: settings.isDark(systemDark: colorScheme == .dark))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if settings.isVisible(.cpu) { filaCPU }
            if settings.isVisible(.memory) { filaMemoria }
            if settings.isVisible(.gpu) { filaGPU }
            if settings.isVisible(.disk) { filaDisco }

            if hayPerifericosVisibles {
                Divider().padding(.vertical, 1)
                perifericos
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(fondo)
        .opacity(settings.opacity)
        .contextMenu { menu }
    }

    /// El tema "Sistema" usa el material translúcido, que deja ver el fondo de
    /// escritorio; los demás son opacos y por eso se leen igual sobre cualquier
    /// cosa. No es un color más: un material no se puede imitar con uno.
    @ViewBuilder
    private var fondo: some View {
        let forma = RoundedRectangle(cornerRadius: 12)
        if let color = paleta.background {
            forma.fill(color)
        } else {
            forma.fill(.regularMaterial)
        }
    }

    // MARK: - Filas de métricas

    private var filaCPU: some View {
        barra("CPU",
              fraccion: model.snapshot.cpu.value?.totalUsage,
              vieja: esVieja(model.snapshot.cpu),
              detalle: model.snapshot.cpu.value.map {
                  String(format: "rendimiento %.0f%%  ·  eficiencia %.0f%%",
                         $0.performanceUsage * 100, $0.efficiencyUsage * 100)
              })
    }

    private var filaMemoria: some View {
        barra("Memoria",
              fraccion: model.snapshot.memory.value?.usedFraction,
              vieja: esVieja(model.snapshot.memory),
              detalle: model.snapshot.memory.value.map {
                  let usada = Double($0.usedBytes) / 1e9
                  let total = Double($0.totalBytes) / 1e9
                  let swap = Double($0.swapUsedBytes) / 1e9
                  return swap > 0.05
                      ? String(format: "%.1f de %.0f GB  ·  swap %.1f GB", usada, total, swap)
                      : String(format: "%.1f de %.0f GB", usada, total)
              })
    }

    private var filaGPU: some View {
        barra("GPU",
              fraccion: model.snapshot.gpu.value?.utilization,
              vieja: esVieja(model.snapshot.gpu),
              detalle: model.snapshot.gpu.value.map {
                  String(format: "%.0f MB en uso", Double($0.inUseMemoryBytes) / 1e6)
              })
    }

    private var filaDisco: some View {
        barra("Disco",
              fraccion: model.snapshot.disk.value?.usedFraction,
              vieja: esVieja(model.snapshot.disk),
              detalle: model.snapshot.disk.value.map {
                  String(format: "%.0f GB libres", Double($0.freeBytes) / 1e9)
              })
    }

    private func barra(_ titulo: String,
                       fraccion: Double?,
                       vieja: Bool,
                       detalle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(titulo)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(paleta.primaryText)
                Spacer(minLength: 0)
                Text(fraccion.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(vieja ? paleta.secondaryText : paleta.primaryText)
            }
            // Un `ProgressView` no deja teñir su carril, y con paletas opacas el
            // carril del sistema desentona sobre el fondo del tema.
            indicador(fraccion: fraccion)
            if let detalle {
                Text(vieja ? "\(detalle)  ·  sin actualizar" : detalle)
                    .font(.system(size: 9))
                    .foregroundStyle(paleta.secondaryText)
                    .lineLimit(1)
            }
        }
        .opacity(vieja ? 0.55 : 1)
    }

    private func indicador(fraccion: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(paleta.track)
                Capsule()
                    .fill(color(para: fraccion))
                    // `max(0, min(1, …))` porque una fracción fuera de rango
                    // dibujaría la barra más allá del carril.
                    .frame(width: geo.size.width * max(0, min(1, fraccion ?? 0)))
            }
        }
        .frame(height: 4)
    }

    /// Holgado por debajo del 70 %, justo hasta el 90 %, al límite por encima.
    /// Qué color es cada tramo lo decide el tema.
    private func color(para fraccion: Double?) -> Color {
        guard let fraccion else { return paleta.idle }
        if fraccion > 0.9 { return paleta.high }
        if fraccion > 0.7 { return paleta.medium }
        return paleta.low
    }

    private func esVieja<T>(_ estado: MetricState<T>) -> Bool {
        if case .stale = estado { return true }
        return false
    }

    // MARK: - Periféricos

    private var hayPerifericosVisibles: Bool {
        settings.isVisible(.pointer) || settings.isVisible(.keyboard)
    }

    @ViewBuilder
    private var perifericos: some View {
        if settings.isVisible(.pointer) {
            switch model.pointerStage {
            case .needsGrant:
                Button {
                    model.openInputMonitoringSettings()
                } label: {
                    Label("Activar detección de trabones", systemImage: "cursorarrow.rays")
                        .font(.system(size: 10))
                }
                .buttonStyle(.link)
            case .needsRestart:
                // macOS solo entrega eventos HID a un proceso arrancado ya con
                // el permiso, así que este botón no es una comodidad: es el
                // único camino desde aquí.
                Button {
                    model.restartApp()
                } label: {
                    Label("Reiniciar para medir el mouse", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.link)
            case .measuring:
                filaPeriferico(
                    "Mouse",
                    valor: textoDelMouse,
                    color: colorDelMouse
                )
            }
        }

        if settings.isVisible(.keyboard),
           let bateria = model.snapshot.peripherals.value?.keyboardBatteryPercent {
            filaPeriferico(
                "Teclado",
                valor: "\(bateria)%",
                color: bateria < 20 ? paleta.high : paleta.secondaryText
            )
        }
    }

    private func filaPeriferico(_ titulo: String,
                                valor: String,
                                color: Color) -> some View {
        HStack(spacing: 6) {
            Text(titulo)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(paleta.primaryText)
            Spacer(minLength: 0)
            Text(valor)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private var textoDelMouse: String {
        guard let salud = model.snapshot.pointer.value else { return "sin señal" }
        guard salud.faults > 0 else { return "estable" }
        return String(format: "%d fallos · %.0f ms",
                      salud.faults, salud.maxFaultGapSeconds * 1000)
    }

    private var colorDelMouse: Color {
        guard let salud = model.snapshot.pointer.value else { return paleta.high }
        return salud.faults > 0 ? paleta.medium : paleta.low
    }

    // MARK: - Menú

    /// Horarios ofrecidos. Configurar horas exactas pide una ventana de ajustes
    /// que esta app no tiene; tres presets cubren el caso real sin inventarla.
    private var horarios: [(claro: Int, oscuro: Int)] {
        [(6, 18), (7, 19), (8, 20)]
    }

    @ViewBuilder
    private var menu: some View {
        Button("Ver consumo y actuar…") { model.showActions() }
        Divider()
        Menu("Mostrar") {
            ForEach(MetricKind.allCases) { metrica in
                Button {
                    settings.toggle(metrica)
                } label: {
                    // La palomita indica que la métrica está visible.
                    Label(metrica.label,
                          systemImage: settings.isVisible(metrica) ? "checkmark" : "")
                }
            }
        }
        Menu("Tema") {
            ForEach(Theme.all) { tema in
                Button {
                    settings.themeID = tema.id
                } label: {
                    Label(tema.name,
                          systemImage: settings.themeID == tema.id ? "checkmark" : "")
                }
            }
        }
        Menu("Claro u oscuro") {
            ForEach(AppearanceMode.allCases) { modo in
                Button {
                    settings.appearance = modo
                } label: {
                    Label(modo.label,
                          systemImage: settings.appearance == modo ? "checkmark" : "")
                }
            }
            if settings.appearance == .schedule {
                Divider()
                ForEach(horarios, id: \.claro) { horario in
                    Button {
                        settings.schedule = AppearanceSchedule(
                            lightStartMinutes: horario.claro * 60,
                            darkStartMinutes: horario.oscuro * 60
                        )
                    } label: {
                        Label(
                            "Claro de \(horario.claro):00 a \(horario.oscuro):00",
                            systemImage: settings.schedule.lightStartMinutes == horario.claro * 60
                                && settings.schedule.darkStartMinutes == horario.oscuro * 60
                                ? "checkmark" : ""
                        )
                    }
                }
            }
        }
        Menu("Opacidad") {
            Button("100 %") { settings.opacity = 1.0 }
            Button("95 %") { settings.opacity = 0.95 }
            Button("80 %") { settings.opacity = 0.8 }
            Button("60 %") { settings.opacity = 0.6 }
        }
        Toggle("Arrancar con el sistema", isOn: $settings.launchAtLogin)
        Divider()
        Button("Salir de Vigía") { NSApplication.shared.terminate(nil) }
    }
}
