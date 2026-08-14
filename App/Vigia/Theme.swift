import SwiftUI

/// Los colores concretos con los que se dibuja el panel.
///
/// Todo lo que la vista pinta sale de aquí. Es lo que hace que añadir un tema
/// sea escribir una paleta y nada más: si una vista eligiera un color por su
/// cuenta, ese color sobreviviría al cambio de tema y rompería el conjunto.
struct Palette: Equatable {
    /// Fondo del panel. `nil` significa usar el material translúcido del
    /// sistema, que no es un color y no se puede imitar con uno.
    var background: Color?
    var primaryText: Color
    var secondaryText: Color
    var tertiaryText: Color
    /// Los tres tramos del indicador: holgado, justo y al límite.
    var low: Color
    var medium: Color
    var high: Color
    /// Cuando no hay dato que mostrar.
    var idle: Color
    /// Fondo del carril del indicador, por detrás de la parte llena.
    var track: Color
}

/// Un tema con sus dos caras.
///
/// Cada tema define claro y oscuro por separado en vez de derivar uno del otro:
/// invertir la luminosidad de una paleta cálida da un resultado sucio, y el
/// verde que se lee bien sobre blanco se apaga sobre negro.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let light: Palette
    let dark: Palette

    func palette(dark usarOscuro: Bool) -> Palette { usarOscuro ? dark : light }

    static let all: [Theme] = [sistema, grafito, ambar, solarizado, neon]

    static func named(_ id: String) -> Theme {
        all.first { $0.id == id } ?? sistema
    }

    /// El aspecto original: material translúcido y colores semánticos de macOS.
    /// Es el único que se adapta al fondo de escritorio que haya detrás.
    static let sistema = Theme(
        id: "sistema",
        name: "Sistema",
        light: Palette(
            background: nil,
            primaryText: .primary, secondaryText: .secondary, tertiaryText: Color.secondary.opacity(0.7),
            low: .green, medium: .orange, high: .red,
            idle: .gray, track: Color.primary.opacity(0.12)
        ),
        dark: Palette(
            background: nil,
            primaryText: .primary, secondaryText: .secondary, tertiaryText: Color.secondary.opacity(0.7),
            low: .green, medium: .orange, high: .red,
            idle: .gray, track: Color.primary.opacity(0.16)
        )
    )

    /// Neutro y sobrio. Sin translucidez, así que se lee igual sobre cualquier
    /// fondo de escritorio.
    static let grafito = Theme(
        id: "grafito",
        name: "Grafito",
        light: Palette(
            background: Color(red: 0.96, green: 0.96, blue: 0.97),
            primaryText: Color(red: 0.13, green: 0.14, blue: 0.16),
            secondaryText: Color(red: 0.40, green: 0.42, blue: 0.45),
            tertiaryText: Color(red: 0.58, green: 0.60, blue: 0.63),
            low: Color(red: 0.20, green: 0.60, blue: 0.40),
            medium: Color(red: 0.85, green: 0.60, blue: 0.15),
            high: Color(red: 0.80, green: 0.25, blue: 0.25),
            idle: Color(red: 0.70, green: 0.72, blue: 0.74),
            track: Color(red: 0.87, green: 0.88, blue: 0.89)
        ),
        dark: Palette(
            background: Color(red: 0.11, green: 0.12, blue: 0.13),
            primaryText: Color(red: 0.92, green: 0.93, blue: 0.94),
            secondaryText: Color(red: 0.64, green: 0.66, blue: 0.69),
            tertiaryText: Color(red: 0.45, green: 0.47, blue: 0.50),
            low: Color(red: 0.35, green: 0.78, blue: 0.55),
            medium: Color(red: 0.95, green: 0.72, blue: 0.30),
            high: Color(red: 0.92, green: 0.40, blue: 0.38),
            idle: Color(red: 0.35, green: 0.37, blue: 0.39),
            track: Color(red: 0.20, green: 0.21, blue: 0.23)
        )
    )

    /// Cálido, sin azules fuertes. Pensado para tenerlo delante de noche: el
    /// azul es la parte del espectro que más despierta.
    static let ambar = Theme(
        id: "ambar",
        name: "Ámbar",
        light: Palette(
            background: Color(red: 0.98, green: 0.96, blue: 0.91),
            primaryText: Color(red: 0.26, green: 0.19, blue: 0.10),
            secondaryText: Color(red: 0.48, green: 0.38, blue: 0.24),
            tertiaryText: Color(red: 0.64, green: 0.55, blue: 0.42),
            low: Color(red: 0.55, green: 0.52, blue: 0.20),
            medium: Color(red: 0.82, green: 0.52, blue: 0.12),
            high: Color(red: 0.76, green: 0.26, blue: 0.14),
            idle: Color(red: 0.75, green: 0.70, blue: 0.62),
            track: Color(red: 0.91, green: 0.87, blue: 0.79)
        ),
        dark: Palette(
            background: Color(red: 0.12, green: 0.09, blue: 0.06),
            primaryText: Color(red: 0.96, green: 0.84, blue: 0.62),
            secondaryText: Color(red: 0.74, green: 0.61, blue: 0.42),
            tertiaryText: Color(red: 0.52, green: 0.42, blue: 0.29),
            low: Color(red: 0.82, green: 0.72, blue: 0.32),
            medium: Color(red: 0.94, green: 0.62, blue: 0.22),
            high: Color(red: 0.90, green: 0.38, blue: 0.24),
            idle: Color(red: 0.36, green: 0.30, blue: 0.22),
            track: Color(red: 0.22, green: 0.17, blue: 0.11)
        )
    )

    /// La paleta de Ethan Schoonover, con sus valores originales.
    static let solarizado = Theme(
        id: "solarizado",
        name: "Solarizado",
        light: Palette(
            background: Color(red: 0.99, green: 0.96, blue: 0.89),   // base3
            primaryText: Color(red: 0.40, green: 0.48, blue: 0.51),  // base00
            secondaryText: Color(red: 0.51, green: 0.58, blue: 0.59),
            tertiaryText: Color(red: 0.58, green: 0.63, blue: 0.63), // base1
            low: Color(red: 0.52, green: 0.60, blue: 0.00),          // green
            medium: Color(red: 0.71, green: 0.54, blue: 0.00),       // yellow
            high: Color(red: 0.86, green: 0.20, blue: 0.18),         // red
            idle: Color(red: 0.79, green: 0.76, blue: 0.68),         // base2
            track: Color(red: 0.93, green: 0.91, blue: 0.84)
        ),
        dark: Palette(
            background: Color(red: 0.00, green: 0.17, blue: 0.21),   // base03
            primaryText: Color(red: 0.51, green: 0.58, blue: 0.59),  // base0
            secondaryText: Color(red: 0.40, green: 0.48, blue: 0.51),
            tertiaryText: Color(red: 0.35, green: 0.43, blue: 0.46), // base01
            low: Color(red: 0.52, green: 0.60, blue: 0.00),
            medium: Color(red: 0.71, green: 0.54, blue: 0.00),
            high: Color(red: 0.86, green: 0.20, blue: 0.18),
            idle: Color(red: 0.03, green: 0.21, blue: 0.26),         // base02
            track: Color(red: 0.03, green: 0.21, blue: 0.26)
        )
    )

    /// Alto contraste, para leerlo de un vistazo desde lejos.
    static let neon = Theme(
        id: "neon",
        name: "Neón",
        light: Palette(
            background: Color(red: 0.99, green: 0.99, blue: 1.0),
            primaryText: Color(red: 0.06, green: 0.06, blue: 0.10),
            secondaryText: Color(red: 0.30, green: 0.30, blue: 0.40),
            tertiaryText: Color(red: 0.50, green: 0.50, blue: 0.60),
            low: Color(red: 0.00, green: 0.62, blue: 0.45),
            medium: Color(red: 0.85, green: 0.45, blue: 0.00),
            high: Color(red: 0.90, green: 0.10, blue: 0.35),
            idle: Color(red: 0.72, green: 0.72, blue: 0.80),
            track: Color(red: 0.90, green: 0.90, blue: 0.95)
        ),
        dark: Palette(
            background: Color(red: 0.04, green: 0.04, blue: 0.07),
            primaryText: Color(red: 0.94, green: 0.96, blue: 1.0),
            secondaryText: Color(red: 0.60, green: 0.64, blue: 0.78),
            tertiaryText: Color(red: 0.40, green: 0.44, blue: 0.56),
            low: Color(red: 0.00, green: 0.95, blue: 0.65),
            medium: Color(red: 1.00, green: 0.75, blue: 0.10),
            high: Color(red: 1.00, green: 0.20, blue: 0.50),
            idle: Color(red: 0.24, green: 0.26, blue: 0.34),
            track: Color(red: 0.12, green: 0.13, blue: 0.18)
        )
    )
}
