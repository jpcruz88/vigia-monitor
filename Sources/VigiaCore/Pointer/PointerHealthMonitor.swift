import Foundation
import IOKit
import IOKit.hid

/// Engancha el mouse por IOKit y alimenta un `GapDetector`.
///
/// Requiere el permiso de Monitoreo de Entrada. Si no lo hay, `start()`
/// devuelve `false` y la aplicación sigue funcionando sin esta métrica.
///
/// **Contrato de vida:** hay que llamar a `stop()` antes de soltar la última
/// referencia. Los callbacks de IOKit guardan un puntero sin dueño a esta
/// instancia (`passUnretained`), así que un gestor todavía abierto y
/// agendado en el run loop puede entregar un evento a memoria ya liberada.
/// No hay `deinit` que lo arregle: un `deinit` que despache a `queue`
/// resucitaría `self` mientras se destruye. Trátala como un objeto de vida
/// larga y ciérrala explícitamente.
///
/// `@unchecked Sendable`: el compilador no puede verificar esta clase porque
/// guarda estado mutable y un `GapDetector`, que tampoco es `Sendable`. La
/// seguridad no la da el compilador sino esta disciplina: `detector` y
/// `lastPublished` solo se tocan dentro de `queue`, que es serial, y
/// `manager`, `matchedDevices` y los dos callbacks públicos solo se tocan
/// desde el hilo que llama a `start()` y `stop()` (en la aplicación, el
/// principal, que es también donde IOKit entrega sus callbacks porque el
/// gestor se agenda en el run loop principal). Nada de eso sale de aquí: el
/// detector se crea adentro y nunca se comparte.
public final class PointerHealthMonitor: @unchecked Sendable {
    /// Se invoca en la cola interna con la salud actualizada.
    public var onHealthUpdate: (@Sendable (PointerHealth) -> Void)?

    /// Se invoca cuando el mouse aparece o desaparece. Un mouse que se
    /// desconecta deja de emitir reportes, así que su caída no puede
    /// notarse por el flujo de eventos: solo IOKit puede avisar.
    public var onAvailabilityChange: (@Sendable (Bool) -> Void)?

    private let queue = DispatchQueue(label: "com.vigia.pointer")
    private var manager: IOHIDManager?
    private var detector = GapDetector(declaredIntervalSeconds: nil)
    private var lastPublished = Date.distantPast
    private var matchedDevices = 0

    public init() {}

    /// Estado del permiso de Monitoreo de Entrada.
    public enum Access: Sendable {
        case granted
        case denied
        /// Nunca se ha preguntado, así que la app todavía no aparece en la
        /// lista de Ajustes del Sistema.
        case undetermined
    }

    /// Consulta el permiso sin pedirlo.
    public static var access: Access {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undetermined
        }
    }

    /// - Returns: `false` si no se pudo arrancar, casi siempre porque falta el
    ///   permiso de Monitoreo de Entrada.
    public func start() -> Bool {
        // Pedir el permiso explícitamente no es opcional, por dos razones que
        // no son evidentes:
        //
        // 1. `IOHIDManagerOpen` devuelve éxito aunque el permiso falte; lo
        //    único que ocurre es que no llega ni un solo evento. Sin esta
        //    comprobación la app creería estar midiendo y mostraría "sin
        //    señal" para siempre, sin explicar por qué.
        // 2. macOS solo lista una app en Ajustes del Sistema → Monitoreo de
        //    entrada después de que la app haya pedido el permiso. Sin pedirlo,
        //    el usuario no tiene ninguna casilla que activar.
        switch Self.access {
        case .granted:
            break
        case .denied:
            return false
        case .undetermined:
            // Muestra el diálogo del sistema y registra la app en la lista.
            guard IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) else { return false }
        }

        let gestor = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let criterio: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(gestor, criterio as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(gestor, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let apertura = IOHIDManagerOpen(gestor, IOOptionBits(kIOHIDOptionsTypeNone))
        guard apertura == kIOReturnSuccess else {
            // Hay que desagendarlo aquí mismo: `manager` sigue en `nil`, así
            // que `stop()` retornaría de inmediato sin limpiar nada. Una
            // aplicación que reintente `start()` cada pocos segundos mientras
            // espera el permiso de Monitoreo de Entrada —que es justo el caso
            // que el diseño exige soportar— iría acumulando gestores
            // agendados en el run loop principal.
            IOHIDManagerUnscheduleFromRunLoop(gestor, CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
            return false
        }

        let contexto = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(gestor, { contexto, _, _, valor in
            guard let contexto else { return }
            let monitor = Unmanaged<PointerHealthMonitor>.fromOpaque(contexto)
                .takeUnretainedValue()
            monitor.handle(valor)
        }, contexto)

        IOHIDManagerRegisterDeviceMatchingCallback(gestor, { contexto, _, _, _ in
            guard let contexto else { return }
            Unmanaged<PointerHealthMonitor>.fromOpaque(contexto)
                .takeUnretainedValue()
                .handleDeviceChange(delta: 1)
        }, contexto)

        IOHIDManagerRegisterDeviceRemovalCallback(gestor, { contexto, _, _, _ in
            guard let contexto else { return }
            Unmanaged<PointerHealthMonitor>.fromOpaque(contexto)
                .takeUnretainedValue()
                .handleDeviceChange(delta: -1)
        }, contexto)

        manager = gestor
        return true
    }

    public func stop() {
        guard let manager else { return }
        // Desregistrar antes de cerrar: un evento en vuelo desreferenciaría
        // el contexto sin dueño.
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(),
                                          CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        matchedDevices = 0
        queue.async { self.detector.reset() }
    }

    /// Descarta el estado acumulado. Se llama al despertar del sueño.
    public func reset() {
        queue.async { self.detector.reset() }
    }

    /// Al desconectarse el mouse hay que descartar las estadísticas: el
    /// siguiente reporte tras reconectar mediría un hueco de minutos contra
    /// el último reporte de antes, y no significaría nada.
    private func handleDeviceChange(delta: Int) {
        matchedDevices = max(0, matchedDevices + delta)
        let disponible = matchedDevices > 0
        queue.async { self.detector.reset() }
        onAvailabilityChange?(disponible)
    }

    private func handle(_ valor: IOHIDValue) {
        let elemento = IOHIDValueGetElement(valor)
        let usagePage = IOHIDElementGetUsagePage(elemento)
        let usage = IOHIDElementGetUsage(elemento)
        // Solo interesan los ejes X e Y del escritorio genérico.
        guard usagePage == UInt32(kHIDPage_GenericDesktop),
              usage == UInt32(kHIDUsage_GD_X) || usage == UInt32(kHIDUsage_GD_Y) else { return }

        let desplazamiento = IOHIDValueGetIntegerValue(valor)
        // El reloj de IOKit viene en tics del reloj absoluto de Mach, no en
        // nanosegundos: en Apple Silicon un tic son ~41.7 ns.
        let marca = Double(IOHIDValueGetTimeStamp(valor)) * Self.nanosPerTick / 1e9
        let reporte = PointerReport(timestamp: marca, moved: desplazamiento != 0)

        queue.async {
            self.detector.record(reporte)
            let ahora = Date()
            // Publicar como mucho una vez por segundo: los reportes llegan
            // hasta mil veces por segundo y la vista no necesita ese ritmo.
            guard ahora.timeIntervalSince(self.lastPublished) >= 1 else { return }
            self.lastPublished = ahora
            self.onHealthUpdate?(self.detector.health(now: marca))
        }
    }

    /// Factor para convertir el reloj absoluto de Mach a nanosegundos.
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()
}
