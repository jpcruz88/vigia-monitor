import Foundation

/// De dónde sale la decisión de usar colores claros u oscuros.
public enum AppearanceMode: String, Sendable, CaseIterable, Identifiable {
    /// Sigue a macOS. Es lo más predecible: el sistema ya trae su propio
    /// automático por amanecer y atardecer, y así Vigía nunca desentona con lo
    /// que hay alrededor.
    case system
    case light
    case dark
    /// Horario propio, para cambiar aunque macOS no lo haga.
    case schedule

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Seguir al sistema"
        case .light: return "Siempre claro"
        case .dark: return "Siempre oscuro"
        case .schedule: return "Por horario"
        }
    }
}

/// A qué hora empieza el día y a qué hora la noche.
///
/// Los minutos se cuentan desde la medianoche, que es lo único que no depende
/// del huso ni del horario de verano: guardar una `Date` obligaría a
/// reinterpretarla cada día, y guardar "19:00" como texto obligaría a
/// analizarlo en cada consulta.
public struct AppearanceSchedule: Sendable, Equatable {
    public var lightStartMinutes: Int
    public var darkStartMinutes: Int

    public static let `default` = AppearanceSchedule(
        lightStartMinutes: 7 * 60,
        darkStartMinutes: 19 * 60
    )

    public init(lightStartMinutes: Int, darkStartMinutes: Int) {
        // Un valor fuera del día daría una franja imposible de satisfacer, y el
        // panel se quedaría en un color sin explicación.
        self.lightStartMinutes = Self.normalizar(lightStartMinutes)
        self.darkStartMinutes = Self.normalizar(darkStartMinutes)
    }

    private static func normalizar(_ minutos: Int) -> Int {
        let dia = 24 * 60
        // `%` en Swift conserva el signo, así que un negativo seguiría negativo.
        return ((minutos % dia) + dia) % dia
    }

    /// `true` si a esa hora toca el aspecto oscuro.
    ///
    /// La franja clara va desde `lightStartMinutes` incluido hasta
    /// `darkStartMinutes` excluido. Cuando la primera es mayor que la segunda
    /// —un turno de noche que pone el claro de 21:00 a 5:00, por ejemplo— la
    /// franja cruza la medianoche y la comparación tiene que invertirse: con un
    /// solo `if` de rango, ese caso daría siempre oscuro.
    public func isDark(at date: Date, calendar: Calendar = .current) -> Bool {
        let componentes = calendar.dateComponents([.hour, .minute], from: date)
        let minutos = (componentes.hour ?? 0) * 60 + (componentes.minute ?? 0)
        return isDark(atMinutes: minutos)
    }

    /// - Parameter minutes: minutos transcurridos desde la medianoche.
    public func isDark(atMinutes minutes: Int) -> Bool {
        let ahora = Self.normalizar(minutes)
        // Sin franja clara de ninguna duración, todo el día es noche. Es la
        // lectura literal de lo que el usuario configuró, y la alternativa
        // —tratarlo como si no hubiera horario— ignoraría su ajuste en silencio.
        guard lightStartMinutes != darkStartMinutes else { return true }

        let esDeDia = lightStartMinutes < darkStartMinutes
            ? (ahora >= lightStartMinutes && ahora < darkStartMinutes)
            : (ahora >= lightStartMinutes || ahora < darkStartMinutes)
        return !esDeDia
    }
}
