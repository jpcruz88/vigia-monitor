import Foundation

public struct PeripheralMetrics: Sendable {
    public let keyboardName: String?
    public let keyboardBatteryPercent: Int?
}

/// Lee el estado de los periféricos Bluetooth.
///
/// La batería no está expuesta en IORegistry: la única fuente es
/// `system_profiler`, que lanza un proceso y tarda segundos. Por eso este
/// muestreador corre cada cinco minutos y siempre con límite de tiempo.
public struct PeripheralSampler {
    private let command: String
    private let arguments: [String]
    private let timeout: TimeInterval

    public init(
        command: String = "/usr/sbin/system_profiler",
        arguments: [String] = ["SPBluetoothDataType", "-json"],
        timeout: TimeInterval = 10
    ) {
        self.command = command
        self.arguments = arguments
        self.timeout = timeout
    }

    public func sample() throws -> PeripheralMetrics {
        let datos = try runCommand()
        return Self.parse(datos)
    }

    /// Ejecuta el comando y aborta si excede el límite de tiempo.
    public func runCommand() throws -> Data {
        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: command)
        proceso.arguments = arguments
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = Pipe()
        try proceso.run()

        let limite = Date().addingTimeInterval(timeout)
        while proceso.isRunning && Date() < limite {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proceso.isRunning {
            proceso.terminate()
            throw SamplerError.processTimedOut(command)
        }
        return salida.fileHandleForReading.readDataToEndOfFile()
    }

    /// Busca de forma recursiva el primer dispositivo con nivel de batería.
    /// La forma exacta del JSON de `system_profiler` cambia entre versiones de
    /// macOS, así que se recorre el árbol en vez de asumir una ruta fija.
    static func parse(_ datos: Data) -> PeripheralMetrics {
        guard let raiz = try? JSONSerialization.jsonObject(with: datos) else {
            return PeripheralMetrics(keyboardName: nil, keyboardBatteryPercent: nil)
        }
        var encontrado: (String, Int)?

        func recorrer(_ nodo: Any, nombrePadre: String?) {
            if encontrado != nil { return }
            if let dicc = nodo as? [String: Any] {
                for (clave, valor) in dicc {
                    if clave.lowercased().contains("battery"),
                       let porcentaje = Self.porcentaje(de: valor) {
                        encontrado = (nombrePadre ?? "desconocido", porcentaje)
                        return
                    }
                    recorrer(valor, nombrePadre: dicc["_name"] as? String ?? clave)
                }
            } else if let lista = nodo as? [Any] {
                for elemento in lista { recorrer(elemento, nombrePadre: nombrePadre) }
            }
        }
        recorrer(raiz, nombrePadre: nil)

        return PeripheralMetrics(
            keyboardName: encontrado?.0,
            keyboardBatteryPercent: encontrado?.1
        )
    }

    /// Acepta tanto `85` como `"85%"`, que ambos aparecen según la versión.
    private static func porcentaje(de valor: Any) -> Int? {
        if let entero = valor as? Int { return entero }
        if let texto = valor as? String {
            return Int(texto.replacingOccurrences(of: "%", with: "")
                            .trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
