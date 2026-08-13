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
public struct PeripheralSampler: Sendable {
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

    public func sample() async throws -> PeripheralMetrics {
        let datos = try await runCommand()
        return Self.parse(datos)
    }

    /// Ejecuta el comando y aborta si excede el límite de tiempo.
    ///
    /// Es `async` de verdad: nada de esperar en bucle. Mientras el hijo corre,
    /// quien llame queda suspendido sin ocupar ningún hilo, y el actor que
    /// pidió el muestreo sigue atendiendo lecturas del snapshot.
    public func runCommand() async throws -> Data {
        let ejecucion = Ejecucion(comando: command, argumentos: arguments)
        return try await withCheckedThrowingContinuation { continuacion in
            ejecucion.arrancar(continuacion, limite: timeout)
        }
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

/// Una ejecución en curso: el proceso, su salida y la continuación que hay
/// que reanudar **exactamente una vez**.
///
/// Tres cosas pueden querer terminar la espera —el proceso al morir, el plazo
/// al vencer y `run()` al fallar— y compiten entre sí. Por eso la
/// continuación se guarda aquí y se entrega bajo candado: quien llega primero
/// se la lleva y los demás encuentran `nil`. Reanudar dos veces una
/// continuación es un fallo fatal, no un aviso.
///
/// `@unchecked Sendable`: `Process` no es `Sendable` y la salida se acumula
/// desde el hilo lector. La seguridad no la da el compilador sino la
/// disciplina: la salida y la continuación solo se tocan bajo `candado`, y
/// `proceso` solo se manipula desde `arrancar` y desde el bloque de
/// vencimiento, que además solo lo toca si ganó la carrera.
private final class Ejecucion: @unchecked Sendable {
    private let comando: String
    private let proceso = Process()
    private let salida = Pipe()
    /// Cola serial. Primero se encola el drenaje del pipe y después la
    /// entrega del resultado: al ser serial, la entrega no puede adelantarse
    /// a la lectura, así que cuando corre la salida ya está completa.
    private let lectura = DispatchQueue(label: "com.vigia.periferico.lectura")
    private let candado = NSLock()
    private var datos = Data()
    private var continuacion: CheckedContinuation<Data, Error>?

    init(comando: String, argumentos: [String]) {
        self.comando = comando
        proceso.executableURL = URL(fileURLWithPath: comando)
        proceso.arguments = argumentos
        proceso.standardOutput = salida
        proceso.standardError = Pipe()
    }

    func arrancar(_ continuacion: CheckedContinuation<Data, Error>, limite: TimeInterval) {
        candado.lock()
        self.continuacion = continuacion
        candado.unlock()

        // `weak` a propósito: el bloque vive dentro de `proceso`, que es
        // propiedad de este objeto, y capturarlo fuerte cerraría un ciclo que
        // filtraría un `Process` por muestreo. Mientras el proceso pueda
        // morir, este objeto sigue vivo: lo retienen el bloque de lectura y
        // el marco de `runCommand`, suspendido en la continuación.
        proceso.terminationHandler = { [weak self] _ in
            guard let self else { return }
            lectura.async { self.entregar(.success(self.leido())) }
        }

        do {
            try proceso.run()
        } catch {
            entregar(.failure(error))
            return
        }

        // Drenar el pipe *mientras* el hijo corre. Esperar a que termine para
        // leer sería una bomba de relojería: en cuanto la salida supere el
        // búfer del pipe (~64 KB) el hijo se bloquea escribiendo, nunca
        // termina, y el límite de tiempo acusa de lento a un comando que
        // funcionó. Este hilo se bloquea hasta el fin de archivo, pero es un
        // hilo propio de la cola, no uno del grupo cooperativo.
        lectura.async {
            let leidos = self.salida.fileHandleForReading.readDataToEndOfFile()
            self.candado.lock()
            self.datos = leidos
            self.candado.unlock()
        }

        // El plazo no se cancela nunca al terminar el proceso: queda como red
        // de seguridad. Si el fin de archivo no llegara (un nieto heredando
        // el pipe, por ejemplo), la entrega quedaría encolada para siempre y
        // sin esto quien llama esperaría eternamente.
        DispatchQueue.global().asyncAfter(deadline: .now() + limite) {
            if self.entregar(.failure(SamplerError.processTimedOut(self.comando))) {
                // Solo el ganador mata al proceso: si otro llegó antes, el
                // proceso ya terminó por su cuenta.
                self.proceso.terminate()
            }
        }
    }

    private func leido() -> Data {
        candado.lock()
        defer { candado.unlock() }
        return datos
    }

    /// - Returns: `true` si esta llamada fue la que reanudó la continuación.
    @discardableResult
    private func entregar(_ resultado: Result<Data, Error>) -> Bool {
        candado.lock()
        let pendiente = continuacion
        continuacion = nil
        candado.unlock()
        guard let pendiente else { return false }
        pendiente.resume(with: resultado)
        return true
    }
}
