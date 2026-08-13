import Foundation
import Testing
@testable import VigiaCore

/// Crea una carpeta personal falsa con contenido, para no tocar la de verdad.
private func hogarDePrueba(_ construir: (URL) throws -> Void) throws -> URL {
    let raiz = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vigia-cleanup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
    try construir(raiz)
    return raiz
}

private func escribir(_ bytes: Int, en url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

@Test("Encuentra los sitios con contenido y los ordena por tamaño")
func encuentraYOrdena() throws {
    let hogar = try hogarDePrueba { raiz in
        try escribir(200_000, en: raiz.appendingPathComponent("Library/Caches/app/uno.bin"))
        try escribir(50_000, en: raiz.appendingPathComponent(".Trash/dos.bin"))
    }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let objetivos = DiskCleanup(home: hogar).scan()
    #expect(objetivos.count == 2)
    #expect(objetivos[0].id == "caches")
    #expect(objetivos[1].id == "trash")
    #expect(objetivos[0].reclaimableBytes > objetivos[1].reclaimableBytes)
    // Cada objetivo debe poder explicarse antes de que el usuario acepte.
    #expect(objetivos.allSatisfy { !$0.explanation.isEmpty })
}

@Test("Un sitio inexistente o vacío no se ofrece")
func vaciosNoSeOfrecen() throws {
    let hogar = try hogarDePrueba { raiz in
        try FileManager.default.createDirectory(
            at: raiz.appendingPathComponent("Library/Caches"), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: hogar) }

    // Ofrecer "recuperar 0 bytes" es ruido: el usuario no tiene nada que decidir.
    #expect(DiskCleanup(home: hogar).scan().isEmpty)
}

@Test("Suma el contenido de subdirectorios enteros")
func sumaRecursiva() throws {
    let hogar = try hogarDePrueba { raiz in
        let base = raiz.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try escribir(100_000, en: base.appendingPathComponent("ProyectoA/build/a.o"))
        try escribir(100_000, en: base.appendingPathComponent("ProyectoA/build/b.o"))
        try escribir(100_000, en: base.appendingPathComponent("ProyectoB/c.o"))
    }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let objetivos = DiskCleanup(home: hogar).scan()
    #expect(objetivos.count == 1)
    #expect(objetivos[0].reclaimableBytes >= 300_000)
    // Dos proyectos de primer nivel, aunque uno tenga varios archivos dentro.
    #expect(objetivos[0].itemCount == 2)
}

@Test("Borrar vacía el contenido pero conserva el directorio")
func borradoConservaElDirectorio() throws {
    let hogar = try hogarDePrueba { raiz in
        try escribir(120_000, en: raiz.appendingPathComponent("Library/Caches/app/uno.bin"))
        try escribir(80_000, en: raiz.appendingPathComponent("Library/Caches/otra.bin"))
    }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let limpieza = DiskCleanup(home: hogar)
    let objetivo = try #require(limpieza.scan().first)
    let liberados = try limpieza.purge(objetivo)

    #expect(liberados >= 200_000)
    // El directorio tiene que seguir ahí: macOS lo crea al arrancar y hay
    // aplicaciones que cuentan con encontrarlo.
    var esDirectorio: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: objetivo.directory.path, isDirectory: &esDirectorio))
    #expect(esDirectorio.boolValue)
    #expect(try FileManager.default.contentsOfDirectory(
        atPath: objetivo.directory.path).isEmpty)
    #expect(limpieza.scan().isEmpty)
}

@Test("Se niega a borrar fuera de la carpeta personal")
func rechazaFueraDelHogar() throws {
    let hogar = try hogarDePrueba { _ in }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let intruso = CleanupTarget(
        id: "intruso", name: "intruso", explanation: "",
        directory: URL(fileURLWithPath: "/Library/Caches"),
        reclaimableBytes: 1, itemCount: 1
    )
    #expect(throws: DiskCleanup.Failure.outsideHome) {
        try DiskCleanup(home: hogar).purge(intruso)
    }
}

/// Sin resolver la ruta, un `..` de más colaría cualquier destino del disco
/// detrás de un prefijo que parece correcto.
@Test("Un rodeo con .. no sortea la comprobación")
func rechazaRodeoConDosPuntos() throws {
    let hogar = try hogarDePrueba { _ in }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let disfrazado = CleanupTarget(
        id: "disfrazado", name: "disfrazado", explanation: "",
        directory: hogar.appendingPathComponent("../../../../System/Library"),
        reclaimableBytes: 1, itemCount: 1
    )
    #expect(throws: DiskCleanup.Failure.outsideHome) {
        try DiskCleanup(home: hogar).purge(disfrazado)
    }
}

@Test("La propia carpeta personal no es un objetivo válido")
func rechazaElHogarEntero() throws {
    let hogar = try hogarDePrueba { _ in }
    defer { try? FileManager.default.removeItem(at: hogar) }

    let todo = CleanupTarget(
        id: "todo", name: "todo", explanation: "",
        directory: hogar, reclaimableBytes: 1, itemCount: 1
    )
    #expect(throws: DiskCleanup.Failure.outsideHome) {
        try DiskCleanup(home: hogar).purge(todo)
    }
}
