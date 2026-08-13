import Foundation
import IOKit
import IOKit.hid

/// Engancha el mouse por IOKit y alimenta un `GapDetector`.
///
/// Requiere el permiso de Monitoreo de Entrada. Si no lo hay, `start()`
/// devuelve `false` y la aplicación sigue funcionando sin esta métrica.
///
/// `@unchecked Sendable`: el compilador no puede verificar esta clase porque
/// guarda estado mutable y un `GapDetector`, que tampoco es `Sendable`. La
/// seguridad no la da el compilador sino esta disciplina: `detector` y
/// `lastPublished` solo se tocan dentro de `queue`, que es serial, y
/// `manager` y `onHealthUpdate` solo se tocan desde el hilo que llama a
/// `start()` y `stop()` (en la aplicación, el principal). Nada de eso sale
/// de aquí: el detector se crea adentro y nunca se comparte.
public final class PointerHealthMonitor: @unchecked Sendable {
    /// Se invoca en la cola interna con la salud actualizada.
    public var onHealthUpdate: (@Sendable (PointerHealth) -> Void)?

    private let queue = DispatchQueue(label: "com.vigia.pointer")
    private var manager: IOHIDManager?
    private var detector = GapDetector(declaredIntervalSeconds: nil)
    private var lastPublished = Date.distantPast

    public init() {}

    /// - Returns: `false` si no se pudo abrir el gestor, casi siempre porque
    ///   falta el permiso de Monitoreo de Entrada.
    public func start() -> Bool {
        let gestor = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let criterio: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Mouse
        ]
        IOHIDManagerSetDeviceMatching(gestor, criterio as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(gestor, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let apertura = IOHIDManagerOpen(gestor, IOOptionBits(kIOHIDOptionsTypeNone))
        guard apertura == kIOReturnSuccess else { return false }

        let contexto = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(gestor, { contexto, _, _, valor in
            guard let contexto else { return }
            let monitor = Unmanaged<PointerHealthMonitor>.fromOpaque(contexto)
                .takeUnretainedValue()
            monitor.handle(valor)
        }, contexto)

        manager = gestor
        return true
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        queue.async { self.detector.reset() }
    }

    /// Descarta el estado acumulado. Se llama al despertar del sueño.
    public func reset() {
        queue.async { self.detector.reset() }
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
