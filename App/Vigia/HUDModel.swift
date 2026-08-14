import Foundation
import SwiftUI
import AppKit
import VigiaCore

/// Une el motor con la vista y gobierna los ritmos de refresco.
///
/// Vive en el actor principal porque `PointerHealthMonitor` exige que
/// `start()` y `stop()` se llamen siempre desde el mismo hilo, y porque la
/// vista lee sus propiedades publicadas.
@MainActor
final class HUDModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .empty
    @Published private(set) var pointerStage: PointerPermissionGate.Stage = .measuring

    private let engine = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler()
    )
    private let pointer = PointerHealthMonitor()
    private var gate = PointerPermissionGate(started: true)
    private var tareas: [Task<Void, Never>] = []

    /// Última salud recibida del mouse y cuándo llegó. Sirven para detectar el
    /// silencio: los reportes HID solo llegan al mover el mouse, así que sin
    /// esto la cuenta de fallos se congelaría en pantalla indefinidamente.
    private var ultimaSalud: PointerHealth?
    private var ultimaSaludRecibida = Date.distantPast
    private var mouseDisponible = true

    private static let claveOrigen = "hud.origin"

    /// `nil` la primera vez: entonces el panel elige una esquina visible por su
    /// cuenta, que no puede decidirse aquí porque depende de su altura final.
    var savedOrigin: NSPoint? {
        guard let guardado = UserDefaults.standard.string(forKey: Self.claveOrigen) else {
            return nil
        }
        return NSPointFromString(guardado)
    }

    func saveOrigin(_ punto: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(punto), forKey: Self.claveOrigen)
    }

    // MARK: - Ciclo de vida

    func start() {
        conectarMouse()

        // Ritmo rápido: CPU, memoria y GPU. Son llamadas al kernel que cuestan
        // microsegundos, así que pueden correr cada segundo sin costo notable.
        tareas.append(bucle(cada: .seconds(1)) { [engine] in
            await engine.refreshFast()
        })
        // El disco cambia despacio y `statfs` toca el sistema de archivos.
        tareas.append(bucle(cada: .seconds(30)) { [engine] in
            await engine.refreshDisk()
        })
        // `system_profiler` lanza un proceso y tarda segundos: cada cinco
        // minutos es lo más seguido que tiene sentido llamarlo.
        tareas.append(bucle(cada: .seconds(300)) { [engine] in
            await engine.refreshPeripherals()
        })
    }

    func stop() {
        tareas.forEach { $0.cancel() }
        tareas.removeAll()
        // Obligatorio antes de soltar la referencia: los callbacks de IOKit
        // guardan un puntero sin dueño a este monitor.
        pointer.stop()
    }

    /// Al despertar del sueño hay que descartar dos acumuladores distintos: los
    /// contadores de CPU, que se calculan por diferencia, y las estadísticas del
    /// mouse, que quedaron congeladas desde antes de dormir.
    func handleWake() {
        Task { [engine, pointer] in
            await engine.resetAccumulators()
            pointer.reset()
        }
        ultimaSalud = nil
        ultimaSaludRecibida = .distantPast
    }

    /// Los ajustes viven aquí, no dentro de la vista, porque el panel y la
    /// ventana de acciones tienen que compartir el mismo objeto: dos instancias
    /// leerían los mismos valores guardados pero no se enterarían de los
    /// cambios de la otra, y elegir "siempre oscuro" dejaría una de las dos
    /// ventanas con el aspecto anterior.
    let settings = SettingsStore()

    /// El controlador vive aquí para que la ventana sobreviva al menú
    /// contextual que la invocó.
    private lazy var actionsWindow = ActionsWindowController(settings: settings)

    func showActions() {
        actionsWindow.show()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Cableado del mouse

    private func conectarMouse() {
        pointer.onHealthUpdate = { [weak self] salud in
            Task { @MainActor [weak self] in
                self?.recibirSalud(salud)
            }
        }
        pointer.onAvailabilityChange = { [weak self] disponible in
            Task { @MainActor [weak self] in
                await self?.cambiarDisponibilidad(disponible)
            }
        }

        gate = PointerPermissionGate(started: pointer.start())
        pointerStage = gate.stage
        if gate.stage != .measuring {
            Task { [engine] in
                await engine.markPointerUnavailable(reason: "permiso requerido")
            }
        }
    }

    /// Vigila si el usuario concedió el permiso mientras la app corría.
    ///
    /// Aquí *no* se reintenta `pointer.start()`, aunque sea tentador: macOS no
    /// aplica el permiso a un proceso ya en marcha, así que un reintento
    /// arrancaría sin error y no llegaría ni un evento. Ver
    /// `PointerPermissionGate` para el razonamiento completo.
    private func revisarPermiso() {
        let anterior = gate.stage
        gate.refresh(access: PointerHealthMonitor.access)
        guard gate.stage != anterior else { return }

        pointerStage = gate.stage
        Task { [engine] in
            await engine.markPointerUnavailable(reason: "reinicia Vigía")
        }
    }

    /// Relanza la aplicación: lo único que hace que macOS entregue eventos HID
    /// después de conceder el permiso.
    ///
    /// La instancia nueva se pide *antes* de terminar esta, y la salida ocurre
    /// en la respuesta. Al revés —terminar y confiar en que algo nos reabra— no
    /// hay nadie que lo haga, y `createsNewApplicationInstance` es obligatorio
    /// porque si no macOS se limita a activar la instancia que todavía vive.
    func restartApp() {
        let configuracion = NSWorkspace.OpenConfiguration()
        configuracion.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuracion
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private func recibirSalud(_ salud: PointerHealth) {
        // Una actualización puede llegar después de que el mouse se desconectó:
        // los dos callbacks vienen por hilos distintos y no hay orden
        // garantizado entre ellos. Descartarla evita que el panel vuelva a
        // afirmar que todo va bien con un dispositivo ausente.
        guard mouseDisponible else { return }
        ultimaSalud = salud
        ultimaSaludRecibida = Date()
        Task { [engine] in await engine.updatePointer(salud) }
    }

    private func cambiarDisponibilidad(_ disponible: Bool) async {
        mouseDisponible = disponible
        if !disponible {
            ultimaSalud = nil
            await engine.markPointerUnavailable(reason: "mouse desconectado")
        }
    }

    /// Un mouse quieto no emite reportes, así que sin esto la última cuenta de
    /// fallos se quedaría en pantalla para siempre. Pasada la ventana móvil sin
    /// noticias, la cuenta correcta es cero: la ventana ya expiró.
    private func caducarSaludDelMouse() async {
        guard mouseDisponible, let ultima = ultimaSalud else { return }
        let silencio = Date().timeIntervalSince(ultimaSaludRecibida)
        guard silencio > GapDetector.windowSeconds else { return }

        let vacia = PointerHealth(
            faults: 0,
            maxFaultGapSeconds: 0,
            expectedIntervalSeconds: ultima.expectedIntervalSeconds
        )
        ultimaSalud = vacia
        await engine.updatePointer(vacia)
    }

    // MARK: - Bucles

    /// Un bucle que se repite hasta que se cancela la tarea. Usa `[weak self]`
    /// porque estas tareas nunca terminan solas: una referencia fuerte
    /// impediría liberar el modelo al cerrar la aplicación.
    private func bucle(
        cada intervalo: Duration,
        _ trabajo: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                await trabajo()
                self?.revisarPermiso()
                await self?.caducarSaludDelMouse()
                await self?.publicar()
                try? await Task.sleep(for: intervalo)
            }
        }
    }

    private func publicar() async {
        snapshot = await engine.snapshot
    }
}
