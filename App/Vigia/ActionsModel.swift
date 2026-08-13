import Foundation
import AppKit
import VigiaCore

/// Estado de la ventana de acciones: quién consume qué, y qué se puede hacer.
///
/// Separado de `HUDModel` a propósito. El panel flotante mide todo el rato y no
/// debe pagar el coste de recorrer seiscientos procesos ni de medir carpetas;
/// esto solo vive mientras la ventana está abierta.
@MainActor
final class ActionsModel: ObservableObject {
    /// Por qué columna se ordena la lista de procesos.
    enum Orden: String, CaseIterable {
        case memoria = "Memoria"
        case cpu = "CPU"
    }

    /// Una acción destructiva a la espera de que el usuario la confirme.
    ///
    /// Todas pasan por aquí. Es lo que hace cumplir la regla de que nada se
    /// cierra ni se borra sin que el usuario haya visto antes qué pierde.
    enum Pendiente: Identifiable {
        case cerrar(ProcessGroup)
        case forzar(ProcessGroup)
        case bajarPrioridad(ProcessGroup)
        case limpiar(CleanupTarget)
        case purgar

        var id: String {
            switch self {
            case .cerrar(let g): return "cerrar-\(g.id)"
            case .forzar(let g): return "forzar-\(g.id)"
            case .bajarPrioridad(let g): return "nice-\(g.id)"
            case .limpiar(let t): return "limpiar-\(t.id)"
            case .purgar: return "purgar"
            }
        }
    }

    @Published private(set) var grupos: [ProcessGroup] = []
    @Published private(set) var objetivos: [CleanupTarget] = []
    @Published private(set) var midiendoDisco = false
    @Published private(set) var aviso: String?
    @Published var orden: Orden = .memoria
    @Published var pendiente: Pendiente?

    /// Prioridad que se aplica al bajarla. 10 es la mitad del rango: se nota sin
    /// dejar el proceso parado.
    @Published var prioridadElegida: Int32 = 10

    private let monitor = ProcessMonitor()
    private let limpieza = DiskCleanup()
    private var tarea: Task<Void, Never>?

    /// Ordenados según la columna elegida. Los que aún no tienen dato de CPU
    /// van al final: no se sabe cuánto gastan, y fingir un cero los pondría
    /// arriba en el orden inverso.
    var grupsOrdenados: [ProcessGroup] {
        switch orden {
        case .memoria: return grupos.sorted { $0.residentBytes > $1.residentBytes }
        case .cpu: return grupos.sorted { ($0.cpuFraction ?? -1) > ($1.cpuFraction ?? -1) }
        }
    }

    // MARK: - Ciclo de vida

    func start() {
        guard tarea == nil else { return }
        tarea = Task { [weak self] in
            while !Task.isCancelled {
                await self?.muestrear()
                // Dos segundos: suficiente para que la diferencia de CPU sea
                // estable y para que la lista no baile mientras se lee.
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task { await medirDisco() }
    }

    func stop() {
        tarea?.cancel()
        tarea = nil
    }

    private func muestrear() async {
        grupos = await monitor.sample()
    }

    func medirDisco() async {
        midiendoDisco = true
        defer { midiendoDisco = false }
        // Recorrer DerivedData puede tardar segundos, así que sale del hilo
        // principal; `DiskCleanup` es un valor sin estado y puede cruzar.
        let limpieza = limpieza
        objetivos = await Task.detached { limpieza.scan() }.value
    }

    // MARK: - Ejecución

    /// Ejecuta lo que el usuario acaba de confirmar.
    func confirmar(_ accion: Pendiente) {
        switch accion {
        case .cerrar(let g): aplicar(g) { try ProcessActions.requestQuit(pid: $0, path: $1) }
        case .forzar(let g): aplicar(g) { try ProcessActions.forceQuit(pid: $0, path: $1) }
        case .bajarPrioridad(let g):
            let nice = prioridadElegida
            aplicar(g) { try ProcessActions.lowerPriority(pid: $0, path: $1, to: nice) }
        case .limpiar(let t): limpiar(t)
        case .purgar: purgar()
        }
        pendiente = nil
    }

    /// Aplica una acción a todos los procesos del grupo.
    ///
    /// A todos, no solo al principal: cerrar el proceso padre de un navegador no
    /// siempre se lleva a sus ayudantes, y dejarlos huérfanos consumiendo
    /// memoria sería justo lo contrario de lo que el usuario pidió.
    ///
    /// El único fallo que se le cuenta al usuario es el del proceso principal.
    /// Que un ayudante ya hubiera muerto —muy probable, porque cerrar el padre
    /// los arrastra— no es algo que deba leer como error.
    private func aplicar(
        _ grupo: ProcessGroup,
        _ accion: (Int32, String) throws -> Void
    ) {
        guard !grupo.isProtected else {
            aviso = "\(grupo.name) es del sistema: Vigía no actúa sobre él."
            return
        }

        for pid in grupo.pids {
            do {
                try accion(pid, grupo.id)
            } catch let error as ProcessActions.Failure where pid == grupo.mainPID {
                aviso = descripcion(de: error, sobre: grupo.name)
                return
            } catch {
                continue
            }
        }
        aviso = nil
        // La lista queda desfasada en cuanto algo se cierra, y esperar al
        // siguiente muestreo daría la sensación de que no pasó nada.
        Task { await muestrear() }
    }

    private func limpiar(_ objetivo: CleanupTarget) {
        let limpieza = limpieza
        Task {
            let liberados = await Task.detached { try? limpieza.purge(objetivo) }.value
            if let liberados {
                aviso = "Se liberaron \(formatear(liberados)) de \(objetivo.name)."
            } else {
                aviso = "No se pudo limpiar \(objetivo.name)."
            }
            await medirDisco()
        }
    }

    private func purgar() {
        Task {
            let purga = MemoryPurge()
            do {
                let resultado = try await Task.detached { try purga.run() }.value
                // Se informa de lo que costó, no solo de lo que "se liberó":
                // la caché descartada hay que releerla del disco.
                aviso = "Libre: \(formatear(resultado.freeBefore)) → "
                    + "\(formatear(resultado.freeAfter)). "
                    + "Se descartaron \(formatear(resultado.cacheDropped)) de caché de disco, "
                    + "que el sistema volverá a leer conforme haga falta."
            } catch MemoryPurge.Failure.cancelled {
                aviso = nil
            } catch {
                aviso = "No se pudo purgar la memoria."
            }
        }
    }

    private func descripcion(de error: ProcessActions.Failure, sobre nombre: String) -> String {
        switch error {
        case .protected: return "\(nombre) es del sistema: Vigía no actúa sobre él."
        case .noSuchProcess: return "\(nombre) ya no estaba en marcha."
        case .notPermitted: return "El sistema no permite actuar sobre \(nombre)."
        case .invalidPriority: return "Esa prioridad no es válida."
        case .unknown(let code): return "No se pudo actuar sobre \(nombre) (error \(code))."
        }
    }
}

/// Bytes en las unidades que usa el resto de la interfaz.
func formatear(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1e9
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1e6)
}
