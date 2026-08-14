import Foundation
import Testing
@testable import VigiaCore

private func minutos(_ hora: Int, _ minuto: Int = 0) -> Int { hora * 60 + minuto }

@Test("El horario normal separa el día de la noche")
func horarioNormal() {
    let horario = AppearanceSchedule.default  // claro de 7:00 a 19:00

    #expect(!horario.isDark(atMinutes: minutos(7)))       // empieza el día
    #expect(!horario.isDark(atMinutes: minutos(12)))
    #expect(!horario.isDark(atMinutes: minutos(18, 59)))
    #expect(horario.isDark(atMinutes: minutos(19)))       // empieza la noche
    #expect(horario.isDark(atMinutes: minutos(23)))
    #expect(horario.isDark(atMinutes: minutos(3)))
    #expect(horario.isDark(atMinutes: minutos(6, 59)))
}

/// Con una sola comparación de rango, este caso daría oscuro las 24 horas.
@Test("Una franja clara que cruza la medianoche se respeta")
func franjaQueCruzaLaMedianoche() {
    // Turno de noche: claro de 21:00 a 5:00.
    let horario = AppearanceSchedule(lightStartMinutes: minutos(21), darkStartMinutes: minutos(5))

    #expect(!horario.isDark(atMinutes: minutos(21)))
    #expect(!horario.isDark(atMinutes: minutos(23, 59)))
    #expect(!horario.isDark(atMinutes: 0))            // medianoche justa
    #expect(!horario.isDark(atMinutes: minutos(4, 59)))
    #expect(horario.isDark(atMinutes: minutos(5)))
    #expect(horario.isDark(atMinutes: minutos(13)))
    #expect(horario.isDark(atMinutes: minutos(20, 59)))
}

@Test("Sin franja clara, todo el día es noche")
func franjaVacia() {
    let horario = AppearanceSchedule(lightStartMinutes: minutos(9), darkStartMinutes: minutos(9))
    #expect(horario.isDark(atMinutes: minutos(9)))
    #expect(horario.isDark(atMinutes: minutos(15)))
    #expect(horario.isDark(atMinutes: minutos(3)))
}

@Test("Las horas imposibles se doblan al día en vez de romper la franja")
func horasFueraDeRango() {
    // 25:00 es 1:00, y -60 es 23:00.
    let horario = AppearanceSchedule(lightStartMinutes: minutos(25), darkStartMinutes: -60)
    #expect(horario.lightStartMinutes == minutos(1))
    #expect(horario.darkStartMinutes == minutos(23))

    #expect(!horario.isDark(atMinutes: minutos(12)))
    #expect(horario.isDark(atMinutes: minutos(23, 30)))
    #expect(horario.isDark(atMinutes: minutos(0, 30)))
}

@Test("La consulta por fecha usa la hora local")
func consultaPorFecha() throws {
    var calendario = Calendar(identifier: .gregorian)
    calendario.timeZone = try #require(TimeZone(identifier: "America/Mexico_City"))

    var componentes = DateComponents()
    componentes.year = 2026
    componentes.month = 8
    componentes.day = 13
    componentes.hour = 22
    componentes.minute = 30
    let noche = try #require(calendario.date(from: componentes))

    componentes.hour = 10
    let dia = try #require(calendario.date(from: componentes))

    #expect(AppearanceSchedule.default.isDark(at: noche, calendar: calendario))
    #expect(!AppearanceSchedule.default.isDark(at: dia, calendar: calendario))
}
