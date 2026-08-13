import Foundation
import Testing
@testable import VigiaCore

// MARK: - Identidad

private let ayudanteDeChrome = "/Applications/Google Chrome.app/Contents/Frameworks/"
    + "Google Chrome Framework.framework/Versions/141.0.7390.123/Helpers/"
    + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

@Test("Un ayudante anidado se atribuye a su aplicación, no a sí mismo")
func ayudanteSeAtribuyeALaApp() {
    // Tomar el último `.app` daría "Google Chrome Helper", que es justo el
    // nombre que no le sirve a nadie.
    #expect(ProcessIdentity.displayName(forExecutablePath: ayudanteDeChrome) == "Google Chrome")
    #expect(ProcessIdentity.groupKey(forExecutablePath: ayudanteDeChrome)
        == "/Applications/Google Chrome.app")
}

@Test("El binario principal y sus ayudantes caen en el mismo grupo")
func principalYAyudantesCompartenGrupo() {
    let principal = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    #expect(ProcessIdentity.groupKey(forExecutablePath: principal)
        == ProcessIdentity.groupKey(forExecutablePath: ayudanteDeChrome))
    #expect(ProcessIdentity.isMainExecutable(ofApp: principal))
    #expect(!ProcessIdentity.isMainExecutable(ofApp: ayudanteDeChrome))
}

@Test("Un ejecutable suelto usa su propio nombre")
func ejecutableSueltoUsaSuNombre() {
    let ruta = "/opt/homebrew/bin/node"
    #expect(ProcessIdentity.displayName(forExecutablePath: ruta) == "node")
    #expect(ProcessIdentity.groupKey(forExecutablePath: ruta) == ruta)
    #expect(ProcessIdentity.isMainExecutable(ofApp: ruta))
}

@Test("Dos aplicaciones con el mismo nombre no se funden en un grupo")
func mismoNombreDistintaRutaNoSeFunden() {
    // Fundirlas haría que cerrar una cerrara la otra.
    let unaA = "/Applications/Editor.app/Contents/MacOS/Editor"
    let otraA = "/Users/apolo/Downloads/Editor.app/Contents/MacOS/Editor"
    #expect(ProcessIdentity.displayName(forExecutablePath: unaA)
        == ProcessIdentity.displayName(forExecutablePath: otraA))
    #expect(ProcessIdentity.groupKey(forExecutablePath: unaA)
        != ProcessIdentity.groupKey(forExecutablePath: otraA))
}

// MARK: - Protección

@Test("Los procesos del sistema están protegidos")
func procesosDelSistemaProtegidos() {
    let intocables = [
        "/System/Library/CoreServices/WindowServer",
        "/usr/sbin/cfprefsd",
        "/bin/zsh",
        "/sbin/launchd",
        "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/MacOS/XProtect"
    ]
    for ruta in intocables {
        #expect(ProcessGuard.isProtected(path: ruta, pid: 500, selfPID: 99), "debería proteger \(ruta)")
    }
}

@Test("Las aplicaciones del usuario no están protegidas")
func aplicacionesDelUsuarioNoProtegidas() {
    #expect(!ProcessGuard.isProtected(path: ayudanteDeChrome, pid: 500, selfPID: 99))
    #expect(!ProcessGuard.isProtected(path: "/opt/homebrew/bin/node", pid: 500, selfPID: 99))
    // `/Library` sin `/Apple` es territorio de terceros: cerrable.
    #expect(!ProcessGuard.isProtected(
        path: "/Library/Application Support/Acme/Agent.app/Contents/MacOS/Agent",
        pid: 500, selfPID: 99))
}

@Test("Finder y compañía están protegidos aunque vivan fuera del sistema")
func criticosProtegidosPorNombre() {
    #expect(ProcessGuard.isProtected(
        path: "/Applications/Finder.app/Contents/MacOS/Finder", pid: 500, selfPID: 99))
    #expect(ProcessGuard.isProtected(
        path: "/Applications/Vigia.app/Contents/MacOS/Vigía", pid: 500, selfPID: 99))
}

@Test("Vigía no puede cerrarse a sí misma")
func vigiaNoSeCierraASiMisma() {
    #expect(ProcessGuard.isProtected(path: "/tmp/lo-que-sea", pid: 42, selfPID: 42))
}

/// `kill(0, …)` se lo manda al grupo de procesos entero: apagaría la sesión.
@Test("Los pid 0 y 1 están protegidos")
func pidsDegeneradosProtegidos() {
    #expect(ProcessGuard.isProtected(path: "/tmp/lo-que-sea", pid: 0, selfPID: 99))
    #expect(ProcessGuard.isProtected(path: "/tmp/lo-que-sea", pid: 1, selfPID: 99))
    #expect(ProcessGuard.isProtected(path: "/tmp/lo-que-sea", pid: -1, selfPID: 99))
}

// MARK: - Acciones

@Test("Las acciones se niegan sobre un proceso protegido")
func accionesRechazanProtegidos() {
    let sistema = "/System/Library/CoreServices/WindowServer"
    #expect(throws: ProcessActions.Failure.protected) {
        try ProcessActions.requestQuit(pid: 500, path: sistema)
    }
    #expect(throws: ProcessActions.Failure.protected) {
        try ProcessActions.forceQuit(pid: 500, path: sistema)
    }
    #expect(throws: ProcessActions.Failure.protected) {
        try ProcessActions.lowerPriority(pid: 500, path: sistema, to: 10)
    }
}

@Test("Una prioridad fuera de rango se rechaza antes de tocar el sistema")
func prioridadFueraDeRango() {
    let ruta = "/opt/homebrew/bin/node"
    // Negativa: subir prioridad exige root y no arregla nada.
    #expect(throws: ProcessActions.Failure.invalidPriority) {
        try ProcessActions.lowerPriority(pid: 500, path: ruta, to: -5)
    }
    #expect(throws: ProcessActions.Failure.invalidPriority) {
        try ProcessActions.lowerPriority(pid: 500, path: ruta, to: 21)
    }
}

@Test("Un proceso inexistente se reporta como tal, no como error genérico")
func procesoInexistente() {
    // Un pid altísimo y libre: el sistema los asigna de forma creciente y
    // circular, así que este no está en uso.
    #expect(throws: ProcessActions.Failure.noSuchProcess) {
        try ProcessActions.requestQuit(pid: 99_998, path: "/opt/homebrew/bin/node")
    }
}

@Test("La prioridad de esta misma prueba se puede leer")
func prioridadPropiaLegible() {
    let propio = ProcessInfo.processInfo.processIdentifier
    #expect(ProcessActions.currentPriority(pid: propio) != nil)
}

// MARK: - Muestreo

@Test("El muestreador encuentra procesos reales y los agrupa")
func muestreadorEncuentraProcesos() {
    let sampler = ProcessSampler()
    let grupos = sampler.sample()

    #expect(!grupos.isEmpty)
    // Esta misma prueba tiene que aparecer, y protegida contra sí misma.
    let propio = ProcessInfo.processInfo.processIdentifier
    let yo = grupos.first { $0.pids.contains(propio) }
    #expect(yo != nil)
    #expect(yo?.isProtected == true)

    // Ordenados por memoria, de mayor a menor.
    let memorias = grupos.map(\.residentBytes)
    #expect(memorias == memorias.sorted(by: >))
    // Ningún grupo sin procesos ni sin nombre.
    #expect(grupos.allSatisfy { !$0.pids.isEmpty && !$0.name.isEmpty })
    #expect(grupos.allSatisfy { $0.pids.contains($0.mainPID) })
}

@Test("La primera muestra no inventa un uso de CPU")
func primeraMuestraSinCPU() {
    // Sin una lectura previa no hay diferencia que calcular, y un cero se leería
    // como "no consume nada", que es una afirmación distinta de "no lo sé".
    let sampler = ProcessSampler()
    let grupos = sampler.sample()
    #expect(grupos.allSatisfy { $0.cpuFraction == nil })
}

@Test("La segunda muestra ya da fracciones de CPU dentro de rango")
func segundaMuestraConCPU() {
    let sampler = ProcessSampler()
    let base = Date()
    _ = sampler.sample(now: base)
    let grupos = sampler.sample(now: base.addingTimeInterval(1))

    #expect(grupos.contains { $0.cpuFraction != nil })
    #expect(grupos.allSatisfy { ($0.cpuFraction ?? 0) >= 0 && ($0.cpuFraction ?? 0) <= 1 })
}

@Test("Reiniciar el muestreador vuelve a dejar la CPU sin dato")
func reiniciarBorraElHistorial() {
    let sampler = ProcessSampler()
    let base = Date()
    _ = sampler.sample(now: base)
    sampler.reset()
    // Tras despertar del sueño, la diferencia contra la muestra vieja sería
    // absurda: mejor no dar dato que dar uno falso.
    let grupos = sampler.sample(now: base.addingTimeInterval(3600))
    #expect(grupos.allSatisfy { $0.cpuFraction == nil })
}
