import Foundation

/// Recuerda la última batería conocida de cada periférico.
///
/// Un teclado o un mouse Bluetooth desaparecen de la lista de conectados en
/// cuanto se duermen o pierden la señal un instante, y su batería no cambia
/// mientras tanto. Sin esta memoria el dato parpadea: aparece y desaparece de
/// la barra al ritmo de la conexión, que es justo lo que inutiliza un
/// indicador pensado para mirarse de reojo.
///
/// La memoria caduca a propósito. Un teclado que se apagó ayer no debe seguir
/// afirmando "100 %": pasado el plazo sin volver a verlo, se olvida y el
/// indicador desaparece, que es la respuesta honesta.
public struct PeripheralMemory: Sendable, Equatable {
    /// Cuánto se conserva una lectura sin volver a ver el dispositivo. Quince
    /// minutos cubren de sobra una desconexión pasajera sin llegar a afirmar
    /// nada sobre un dispositivo que se apagó de verdad.
    public static let defaultRetention: TimeInterval = 15 * 60

    private struct Recuerdo: Sendable, Equatable {
        let nombre: String?
        let porcentaje: Int
        let visto: Date
    }

    private var teclado: Recuerdo?
    private var mouse: Recuerdo?
    private let retention: TimeInterval

    public init(retention: TimeInterval = PeripheralMemory.defaultRetention) {
        self.retention = retention
    }

    /// Mezcla la muestra recién tomada con lo que se recuerda y devuelve lo
    /// que debe verse.
    public mutating func merge(_ fresca: PeripheralMetrics,
                               now: Date = Date()) -> PeripheralMetrics {
        teclado = actualizar(teclado,
                             nombre: fresca.keyboardName,
                             porcentaje: fresca.keyboardBatteryPercent,
                             now: now)
        mouse = actualizar(mouse,
                           nombre: fresca.mouseName,
                           porcentaje: fresca.mouseBatteryPercent,
                           now: now)
        return PeripheralMetrics(
            keyboardName: teclado?.nombre,
            keyboardBatteryPercent: teclado?.porcentaje,
            mouseName: mouse?.nombre,
            mouseBatteryPercent: mouse?.porcentaje
        )
    }

    private func actualizar(_ recuerdo: Recuerdo?,
                            nombre: String?,
                            porcentaje: Int?,
                            now: Date) -> Recuerdo? {
        if let porcentaje {
            return Recuerdo(nombre: nombre, porcentaje: porcentaje, visto: now)
        }
        // Sin lectura nueva: se conserva la anterior mientras no caduque.
        guard let recuerdo, now.timeIntervalSince(recuerdo.visto) < retention else {
            return nil
        }
        return recuerdo
    }
}
