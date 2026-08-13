# Vigía Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir un panel flotante siempre visible para un Mac mini M4 que muestre CPU, memoria, GPU, disco y la salud de la señal del mouse, detectando pérdidas de paquetes del dongle 2.4 GHz que ninguna herramienta existente ve.

**Architecture:** Un paquete SPM (`VigiaCore`) contiene toda la lógica —seis muestreadores independientes, un detector de trabones y un motor coordinador— y se prueba desde la línea de comandos sin interfaz. Una app de Xcode (`Vigia`) consume ese paquete y dibuja un `NSPanel` flotante. El flujo es unidireccional: muestreadores → motor → snapshot inmutable → vista.

**Tech Stack:** Swift 6.3, swift-testing, SwiftUI, AppKit (`NSPanel`), IOKit (`IOAccelerator`, `IOHIDManager`), Mach (`host_statistics64`, `host_processor_info`), SPM + Xcode 26.4.

**Spec:** `docs/superpowers/specs/2026-08-13-monitor-mac-design.md`

---

## Verificaciones previas ya realizadas

Estas APIs fueron compiladas y ejecutadas en la máquina objetivo antes de escribir el plan. No hay que investigarlas de nuevo:

| API | Resultado en la máquina real |
|---|---|
| `host_statistics64` | libre 0.15 GB, comprimida 6.21 GB |
| `sysctlbyname("vm.swapusage")` | 6.36 GB usados de 7.52 GB |
| `IOAccelerator` → `PerformanceStatistics` | uso 8%, memoria en uso 296 MB |
| `statfs("/System/Volumes/Data")` | 34.4 GB libres de 245.1 GB |
| `host_processor_info` | 10 núcleos; `hw.perflevel0.logicalcpu`=4 (P), `hw.perflevel1.logicalcpu`=6 (E) |
| `swift test` con `import Testing` | funciona en SPM |

**Orden de los núcleos:** los índices 0–5 muestran el perfil de carga sostenida propio de los E-cores y los 6–9 el perfil intermitente de los P-cores. La Tarea 7 incluye un paso para confirmarlo empíricamente antes de fijarlo.

---

## Estructura de archivos

```
vigia-monitor/
├── Package.swift                                   Paquete SPM: librería VigiaCore + pruebas
├── Sources/VigiaCore/
│   ├── Snapshot/MetricState.swift                  Los tres estados de una métrica
│   ├── Snapshot/SystemSnapshot.swift               Lo que la vista consume
│   ├── Samplers/SamplerError.swift                 Errores compartidos de muestreo
│   ├── Samplers/MemorySampler.swift                Mach: memoria y swap
│   ├── Samplers/CPUSampler.swift                   Mach: CPU con diferencia entre muestras
│   ├── Samplers/GPUSampler.swift                   IORegistry: uso y memoria de GPU
│   ├── Samplers/DiskSampler.swift                  statfs
│   ├── Samplers/PeripheralSampler.swift            system_profiler con límite de tiempo
│   ├── Pointer/GapDetector.swift                   Algoritmo puro de detección de trabones
│   ├── Pointer/PointerHealthMonitor.swift          IOHIDManager → GapDetector
│   └── Engine/MetricsEngine.swift                  Ritmos, aislamiento de fallos, publicación
├── Tests/VigiaCoreTests/
│   ├── GapDetectorTests.swift
│   ├── SamplerTests.swift
│   └── MetricsEngineTests.swift
└── App/Vigia/                                      Proyecto Xcode
    ├── VigiaApp.swift                              Punto de entrada, sin Dock
    ├── HUDPanel.swift                              NSPanel flotante
    ├── HUDView.swift                               SwiftUI, sin lógica
    ├── Settings.swift                              UserDefaults
    └── Info.plist                                  LSUIElement + descripción de permiso
```

**Por qué este corte:** la lógica vive en un paquete que se prueba con `swift test` en segundos, sin abrir Xcode ni pedir permisos. Solo las Tareas 12–15 tocan la app, y para entonces todo lo demás ya está probado.

---

### Task 1: Andamiaje del paquete y arranque de las pruebas

**Files:**
- Create: `Package.swift`
- Create: `Sources/VigiaCore/Snapshot/MetricState.swift`
- Test: `Tests/VigiaCoreTests/GapDetectorTests.swift`

- [ ] **Step 1: Crear el manifiesto del paquete**

Crear `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VigiaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VigiaCore", targets: ["VigiaCore"])
    ],
    targets: [
        .target(name: "VigiaCore"),
        .testTarget(name: "VigiaCoreTests", dependencies: ["VigiaCore"])
    ]
)
```

- [ ] **Step 2: Crear un tipo mínimo para que el target compile**

Crear `Sources/VigiaCore/Snapshot/MetricState.swift`:

```swift
import Foundation

/// El estado en que puede estar una métrica del snapshot.
/// Un muestreador que falla nunca tumba a los demás: su métrica pasa a
/// `unavailable` o `stale` y el resto del panel sigue vivo.
public enum MetricState<Value: Sendable>: Sendable {
    case ok(Value)
    case unavailable(reason: String)
    case stale(Value, since: Date)

    /// El valor si existe, sin importar si es fresco o viejo.
    public var value: Value? {
        switch self {
        case .ok(let v): return v
        case .stale(let v, _): return v
        case .unavailable: return nil
        }
    }
}
```

- [ ] **Step 3: Escribir una prueba que falla**

Crear `Tests/VigiaCoreTests/GapDetectorTests.swift`:

```swift
import Testing
@testable import VigiaCore

@Test("El arnés de pruebas corre y MetricState conserva su valor")
func metricStateConservaValor() {
    let estado = MetricState<Int>.ok(42)
    #expect(estado.value == 42)

    let viejo = MetricState<Int>.stale(7, since: Date(timeIntervalSince1970: 0))
    #expect(viejo.value == 7)

    let ausente = MetricState<Int>.unavailable(reason: "prueba")
    #expect(ausente.value == nil)
}
```

- [ ] **Step 4: Ejecutar las pruebas**

Run: `swift test`
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Andamiaje del paquete VigiaCore con MetricState"
```

---

### Task 2: GapDetector — flujo continuo no produce fallos

**Files:**
- Create: `Sources/VigiaCore/Pointer/GapDetector.swift`
- Modify: `Tests/VigiaCoreTests/GapDetectorTests.swift`

Esta es la pieza central del proyecto. Se construye en tres tareas, una por comportamiento.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/GapDetectorTests.swift`:

```swift
/// Genera reportes regulares, todos con movimiento.
private func flujoRegular(intervalo: Double, cantidad: Int, desde: Double = 0) -> [PointerReport] {
    (0..<cantidad).map { PointerReport(timestamp: desde + Double($0) * intervalo, moved: true) }
}

@Test("Un flujo continuo y regular no produce ningún fallo")
func flujoContinuoSinFallos() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 500) {
        detector.record(reporte)
    }
    let salud = detector.health(now: 0.5)
    #expect(salud.faults == 0)
    #expect(salud.maxGapSeconds == 0)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'GapDetector' in scope`.

- [ ] **Step 3: Implementar lo mínimo**

Crear `Sources/VigiaCore/Pointer/GapDetector.swift`:

```swift
import Foundation

/// Un reporte del mouse ya normalizado, independiente de IOKit.
/// Mantenerlo libre de tipos de IOKit es lo que permite probar el
/// algoritmo sin hardware.
public struct PointerReport: Sendable, Equatable {
    /// Marca de tiempo monotónica, en segundos.
    public let timestamp: Double
    /// true si el reporte trae desplazamiento distinto de cero.
    public let moved: Bool

    public init(timestamp: Double, moved: Bool) {
        self.timestamp = timestamp
        self.moved = moved
    }
}

/// Resultado del detector sobre la ventana móvil.
public struct PointerHealth: Sendable, Equatable {
    public let faults: Int
    public let maxGapSeconds: Double
    public let expectedIntervalSeconds: Double

    public init(faults: Int, maxGapSeconds: Double, expectedIntervalSeconds: Double) {
        self.faults = faults
        self.maxGapSeconds = maxGapSeconds
        self.expectedIntervalSeconds = expectedIntervalSeconds
    }
}

/// Detecta pérdidas de señal del mouse midiendo huecos entre reportes.
///
/// No es seguro para uso concurrente: `PointerHealthMonitor` lo confina
/// a una sola cola.
public final class GapDetector {
    /// Un hueco cuenta como fallo si supera este múltiplo del intervalo esperado.
    public static let gapMultiplier: Double = 4.0
    /// Ventana móvil de estadísticas, en segundos.
    public static let windowSeconds: Double = 60.0
    /// Intervalo supuesto mientras no hay datos suficientes (125 Hz).
    public static let bootstrapInterval: Double = 0.008

    private let declaredInterval: Double?
    private var observedIntervals: [Double] = []
    private var last: PointerReport?
    private var faults: [(at: Double, gap: Double)] = []

    /// - Parameter declaredIntervalSeconds: el `ReportInterval` que declara el
    ///   dispositivo. Si es `nil`, el detector usa la mediana observada.
    public init(declaredIntervalSeconds: Double?) {
        self.declaredInterval = declaredIntervalSeconds
    }

    public var expectedIntervalSeconds: Double {
        if let declaredInterval { return declaredInterval }
        guard !observedIntervals.isEmpty else { return Self.bootstrapInterval }
        let ordenados = observedIntervals.sorted()
        return ordenados[ordenados.count / 2]
    }

    public func record(_ report: PointerReport) {
        defer { last = report }
        guard let previo = last else { return }
        let hueco = report.timestamp - previo.timestamp
        guard hueco > 0 else { return }

        if hueco > expectedIntervalSeconds * Self.gapMultiplier {
            faults.append((at: report.timestamp, gap: hueco))
        } else {
            observedIntervals.append(hueco)
            if observedIntervals.count > 500 {
                observedIntervals.removeFirst(observedIntervals.count - 500)
            }
        }
        prune(now: report.timestamp)
    }

    public func health(now: Double) -> PointerHealth {
        prune(now: now)
        return PointerHealth(
            faults: faults.count,
            maxGapSeconds: faults.map(\.gap).max() ?? 0,
            expectedIntervalSeconds: expectedIntervalSeconds
        )
    }

    /// Descarta todo el estado acumulado. Se llama cuando el mouse se
    /// desconecta y cuando el Mac despierta.
    public func reset() {
        last = nil
        faults.removeAll()
        observedIntervals.removeAll()
    }

    private func prune(now: Double) {
        let corte = now - Self.windowSeconds
        faults.removeAll { $0.at < corte }
    }
}
```

- [ ] **Step 4: Ejecutar y verificar que pasa**

Run: `swift test`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Pointer/GapDetector.swift Tests/VigiaCoreTests/GapDetectorTests.swift
git commit -m "GapDetector: flujo continuo no produce fallos"
```

---

### Task 3: GapDetector — detectar una pérdida real de señal

**Files:**
- Modify: `Tests/VigiaCoreTests/GapDetectorTests.swift`

El código de la Tarea 2 ya debería pasar esta prueba. Se escribe igual para dejarla fijada: es el comportamiento por el que existe el proyecto.

- [ ] **Step 1: Escribir la prueba**

Añadir a `Tests/VigiaCoreTests/GapDetectorTests.swift`:

```swift
@Test("Un hueco de 80 ms en medio del movimiento cuenta como un fallo")
func huecoCuentaComoFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    // 100 reportes normales, luego un salto de 80 ms, luego 100 más.
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100) {
        detector.record(reporte)
    }
    let despuesDelHueco = 0.100 + 0.080
    detector.record(PointerReport(timestamp: despuesDelHueco, moved: true))
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100, desde: despuesDelHueco + 0.001) {
        detector.record(reporte)
    }

    let salud = detector.health(now: 0.3)
    #expect(salud.faults == 1)
    #expect(abs(salud.maxGapSeconds - 0.080) < 0.001)
}

@Test("Los fallos salen de la ventana móvil al pasar 60 segundos")
func fallosExpiranDeLaVentana() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    detector.record(PointerReport(timestamp: 0, moved: true))
    detector.record(PointerReport(timestamp: 0.080, moved: true))
    #expect(detector.health(now: 0.1).faults == 1)
    // Ya pasó más de un minuto desde el fallo.
    #expect(detector.health(now: 61.0).faults == 0)
}
```

- [ ] **Step 2: Ejecutar**

Run: `swift test`
Expected: PASS, 4 tests. Si `huecoCuentaComoFallo` falla, revisar que `gapMultiplier` sea 4 y que el intervalo declarado sea 0.001 (umbral = 4 ms, el hueco de 80 ms debe superarlo).

- [ ] **Step 3: Commit**

```bash
git add Tests/VigiaCoreTests/GapDetectorTests.swift
git commit -m "GapDetector: fijar deteccion de huecos y expiracion de la ventana"
```

---

### Task 4: GapDetector — el reposo no puede contar como fallo

**Files:**
- Modify: `Sources/VigiaCore/Pointer/GapDetector.swift`
- Modify: `Tests/VigiaCoreTests/GapDetectorTests.swift`

Este es el caso que más fácil se rompe. Un mouse HID solo emite reportes cuando algo cambia: si sueltas el mouse diez segundos, el siguiente reporte llega con un hueco de diez segundos. Sin protección, cada pausa para escribir contaría como pérdida de señal.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/GapDetectorTests.swift`:

```swift
@Test("Diez segundos de reposo no cuentan como fallo")
func reposoNoEsFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100) {
        detector.record(reporte)
    }
    // El usuario suelta el mouse y vuelve diez segundos después.
    detector.record(PointerReport(timestamp: 10.0, moved: true))
    for reporte in flujoRegular(intervalo: 0.001, cantidad: 100, desde: 10.001) {
        detector.record(reporte)
    }
    #expect(detector.health(now: 10.2).faults == 0)
}

@Test("Un hueco tras un reporte sin movimiento no cuenta como fallo")
func huecoTrasReposoNoEsFallo() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    detector.record(PointerReport(timestamp: 0, moved: true))
    // Un reporte sin desplazamiento, por ejemplo el de soltar un botón.
    detector.record(PointerReport(timestamp: 0.001, moved: false))
    detector.record(PointerReport(timestamp: 0.081, moved: true))
    #expect(detector.health(now: 0.1).faults == 0)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `reposoNoEsFallo` reporta 1 fallo en vez de 0, porque el hueco de 10 s supera el umbral.

- [ ] **Step 3: Añadir el techo y la condición de movimiento**

En `Sources/VigiaCore/Pointer/GapDetector.swift`, añadir la constante junto a las otras:

```swift
    /// Por encima de este hueco se considera pausa humana, no pérdida de señal.
    /// Una pérdida real del dongle dura decenas o pocos cientos de milisegundos.
    public static let humanPauseThreshold: Double = 0.5
```

Y reemplazar el cuerpo de `record(_:)` completo por:

```swift
    public func record(_ report: PointerReport) {
        defer { last = report }
        guard let previo = last else { return }
        let hueco = report.timestamp - previo.timestamp
        guard hueco > 0 else { return }

        // Solo cuenta si ocurre en medio de movimiento continuo.
        guard previo.moved, report.moved else { return }
        // Un hueco enorme es el usuario soltando el mouse, no el dongle fallando.
        guard hueco < Self.humanPauseThreshold else { return }

        if hueco > expectedIntervalSeconds * Self.gapMultiplier {
            faults.append((at: report.timestamp, gap: hueco))
        } else {
            observedIntervals.append(hueco)
            if observedIntervals.count > 500 {
                observedIntervals.removeFirst(observedIntervals.count - 500)
            }
        }
        prune(now: report.timestamp)
    }
```

- [ ] **Step 4: Ejecutar y verificar que pasan todas**

Run: `swift test`
Expected: PASS, 6 tests. Las pruebas de las Tareas 2 y 3 deben seguir pasando: el hueco de 80 ms sigue por debajo del techo de 500 ms.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Pointer/GapDetector.swift Tests/VigiaCoreTests/GapDetectorTests.swift
git commit -m "GapDetector: distinguir reposo del usuario de perdida de senal"
```

---

### Task 5: MemorySampler

**Files:**
- Create: `Sources/VigiaCore/Samplers/SamplerError.swift`
- Create: `Sources/VigiaCore/Samplers/MemorySampler.swift`
- Test: `Tests/VigiaCoreTests/SamplerTests.swift`

- [ ] **Step 1: Escribir la prueba que falla**

Crear `Tests/VigiaCoreTests/SamplerTests.swift`:

```swift
import Testing
import Foundation
@testable import VigiaCore

@Test("MemorySampler devuelve cifras coherentes con el hardware")
func memoriaCoherente() throws {
    let metricas = try MemorySampler().sample()
    // El Mac mini objetivo tiene 16 GB; se acepta cualquier equipo de 4 GB en adelante.
    #expect(metricas.totalBytes > 4_000_000_000)
    #expect(metricas.freeBytes < metricas.totalBytes)
    #expect(metricas.swapUsedBytes <= metricas.swapTotalBytes)
    #expect(metricas.usedFraction >= 0 && metricas.usedFraction <= 1)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'MemorySampler' in scope`.

- [ ] **Step 3: Implementar**

Crear `Sources/VigiaCore/Samplers/SamplerError.swift`:

```swift
import Foundation

public enum SamplerError: Error, CustomStringConvertible {
    case machCall(String, Int32)
    case sysctlFailed(String)
    case registryKeyMissing(String)
    case processTimedOut(String)

    public var description: String {
        switch self {
        case .machCall(let fn, let code): return "\(fn) devolvió \(code)"
        case .sysctlFailed(let name): return "sysctl \(name) falló"
        case .registryKeyMissing(let key): return "falta la clave \(key) en IORegistry"
        case .processTimedOut(let cmd): return "\(cmd) excedió su límite de tiempo"
        }
    }
}
```

Crear `Sources/VigiaCore/Samplers/MemorySampler.swift`:

```swift
import Foundation

public struct MemoryMetrics: Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let compressedBytes: UInt64
    public let wiredBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64

    /// Fracción de la RAM que no está libre, entre 0 y 1.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

public struct MemorySampler {
    public init() {}

    public func sample() throws -> MemoryMetrics {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            throw SamplerError.machCall("host_statistics64", kr)
        }

        let page = UInt64(vm_kernel_page_size)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else {
            throw SamplerError.sysctlFailed("vm.swapusage")
        }

        return MemoryMetrics(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(stats.free_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            swapUsedBytes: swap.xsu_used,
            swapTotalBytes: swap.xsu_total
        )
    }
}
```

- [ ] **Step 4: Ejecutar**

Run: `swift test`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Samplers Tests/VigiaCoreTests/SamplerTests.swift
git commit -m "MemorySampler leyendo memoria y swap desde Mach"
```

---

### Task 6: DiskSampler

**Files:**
- Create: `Sources/VigiaCore/Samplers/DiskSampler.swift`
- Modify: `Tests/VigiaCoreTests/SamplerTests.swift`

Se hace antes que CPU y GPU porque es el más simple y deja el patrón claro.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/SamplerTests.swift`:

```swift
@Test("DiskSampler concuerda con el tamaño real del volumen")
func discoCoherente() throws {
    let metricas = try DiskSampler().sample()
    #expect(metricas.totalBytes > 10_000_000_000)
    #expect(metricas.freeBytes <= metricas.totalBytes)
    #expect(metricas.usedFraction >= 0 && metricas.usedFraction <= 1)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'DiskSampler' in scope`.

- [ ] **Step 3: Implementar**

Crear `Sources/VigiaCore/Samplers/DiskSampler.swift`:

```swift
import Foundation

public struct DiskMetrics: Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(totalBytes - freeBytes) / Double(totalBytes)
    }
}

public struct DiskSampler {
    /// En macOS moderno los datos del usuario viven en este volumen, no en `/`,
    /// que es de solo lectura y siempre se ve casi vacío.
    public static let dataVolume = "/System/Volumes/Data"

    private let path: String

    public init(path: String = DiskSampler.dataVolume) {
        self.path = path
    }

    public func sample() throws -> DiskMetrics {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            throw SamplerError.sysctlFailed("statfs \(path)")
        }
        let blockSize = UInt64(fs.f_bsize)
        return DiskMetrics(
            totalBytes: UInt64(fs.f_blocks) * blockSize,
            freeBytes: UInt64(fs.f_bavail) * blockSize
        )
    }
}
```

- [ ] **Step 4: Ejecutar**

Run: `swift test`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Samplers/DiskSampler.swift Tests/VigiaCoreTests/SamplerTests.swift
git commit -m "DiskSampler sobre el volumen de datos"
```

---

### Task 7: CPUSampler con diferencia entre muestras

**Files:**
- Create: `Sources/VigiaCore/Samplers/CPUSampler.swift`
- Modify: `Tests/VigiaCoreTests/SamplerTests.swift`

El uso de CPU no es un valor instantáneo: hay que restar dos lecturas de contadores acumulados. La primera llamada no puede devolver un porcentaje.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/SamplerTests.swift`:

```swift
@Test("CPUSampler necesita dos muestras y luego da porcentajes válidos")
func cpuNecesitaDosMuestras() throws {
    let muestreador = CPUSampler()
    // La primera lectura solo siembra los contadores.
    #expect(try muestreador.sample() == nil)

    // Generar algo de trabajo para que los contadores avancen.
    var suma = 0.0
    for i in 0..<2_000_000 { suma += Double(i).squareRoot() }
    #expect(suma > 0)

    let metricas = try #require(try muestreador.sample())
    #expect(metricas.totalUsage >= 0 && metricas.totalUsage <= 1)
    #expect(metricas.performanceUsage >= 0 && metricas.performanceUsage <= 1)
    #expect(metricas.efficiencyUsage >= 0 && metricas.efficiencyUsage <= 1)
    #expect(metricas.coreCount == 10 || metricas.coreCount > 0)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'CPUSampler' in scope`.

- [ ] **Step 3: Implementar**

Crear `Sources/VigiaCore/Samplers/CPUSampler.swift`:

```swift
import Foundation

public struct CPUMetrics: Sendable {
    /// Fracción ocupada de todos los núcleos, entre 0 y 1.
    public let totalUsage: Double
    /// Fracción ocupada solo de los núcleos de rendimiento.
    public let performanceUsage: Double
    /// Fracción ocupada solo de los núcleos de eficiencia.
    public let efficiencyUsage: Double
    public let coreCount: Int
}

/// Lee los contadores acumulados de CPU y calcula el uso por diferencia.
///
/// No es seguro para uso concurrente: guarda la muestra anterior.
public final class CPUSampler {
    private var previous: [(busy: Double, total: Double)] = []
    private let efficiencyCoreCount: Int
    private let performanceCoreCount: Int

    public init() {
        performanceCoreCount = CPUSampler.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCoreCount = CPUSampler.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
    }

    /// Descarta la muestra anterior. Obligatorio tras despertar del sueño:
    /// la diferencia contra una muestra de antes de dormir da un pico falso.
    public func reset() {
        previous = []
    }

    /// Devuelve `nil` en la primera llamada, cuando aún no hay con qué comparar.
    public func sample() throws -> CPUMetrics? {
        let actual = try Self.readCounters()
        defer { previous = actual }
        guard !previous.isEmpty, previous.count == actual.count else { return nil }

        var porNucleo: [Double] = []
        for (anterior, ahora) in zip(previous, actual) {
            let deltaTotal = ahora.total - anterior.total
            let deltaBusy = ahora.busy - anterior.busy
            porNucleo.append(deltaTotal > 0 ? max(0, min(1, deltaBusy / deltaTotal)) : 0)
        }

        // En Apple Silicon los núcleos de eficiencia ocupan los primeros
        // índices del arreglo y los de rendimiento los últimos.
        let e = min(efficiencyCoreCount, porNucleo.count)
        let eficiencia = Array(porNucleo.prefix(e))
        let rendimiento = Array(porNucleo.dropFirst(e))

        return CPUMetrics(
            totalUsage: promedio(porNucleo),
            performanceUsage: promedio(rendimiento),
            efficiencyUsage: promedio(eficiencia),
            coreCount: porNucleo.count
        )
    }

    private func promedio(_ valores: [Double]) -> Double {
        guard !valores.isEmpty else { return 0 }
        return valores.reduce(0, +) / Double(valores.count)
    }

    private static func readCounters() throws -> [(busy: Double, total: Double)] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                    &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else {
            throw SamplerError.machCall("host_processor_info", kr)
        }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var resultado: [(busy: Double, total: Double)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = Double(info[base + Int(CPU_STATE_USER)])
            let sistema = Double(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = Double(info[base + Int(CPU_STATE_NICE)])
            let idle = Double(info[base + Int(CPU_STATE_IDLE)])
            let ocupado = user + sistema + nice
            resultado.append((busy: ocupado, total: ocupado + idle))
        }
        return resultado
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var valor: Int32 = 0
        var tamano = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &valor, &tamano, nil, 0) == 0 else { return nil }
        return Int(valor)
    }
}
```

- [ ] **Step 4: Ejecutar**

Run: `swift test`
Expected: PASS, 9 tests.

- [ ] **Step 5: Confirmar empíricamente el orden de los núcleos**

El reparto entre núcleos de eficiencia y rendimiento depende de que los E-cores ocupen los primeros índices. Verificarlo antes de darlo por bueno:

Run: `swift test --filter cpuNecesitaDosMuestras -v` mientras se ejecuta en otra terminal `yes > /dev/null` (una carga de un solo hilo, que macOS coloca en un núcleo de rendimiento).

Expected: `performanceUsage` claramente mayor que `efficiencyUsage`. Si sale al revés, invertir el corte en `sample()` usando `performanceCoreCount` como prefijo y documentarlo con un comentario.

- [ ] **Step 6: Commit**

```bash
git add Sources/VigiaCore/Samplers/CPUSampler.swift Tests/VigiaCoreTests/SamplerTests.swift
git commit -m "CPUSampler con diferencia entre muestras y reparto P/E"
```

---

### Task 8: GPUSampler

**Files:**
- Create: `Sources/VigiaCore/Samplers/GPUSampler.swift`
- Modify: `Tests/VigiaCoreTests/SamplerTests.swift`

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/SamplerTests.swift`:

```swift
@Test("GPUSampler lee uso y memoria desde IORegistry")
func gpuCoherente() throws {
    let metricas = try GPUSampler().sample()
    #expect(metricas.utilization >= 0 && metricas.utilization <= 1)
    #expect(metricas.inUseMemoryBytes > 0)
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'GPUSampler' in scope`.

- [ ] **Step 3: Implementar**

Crear `Sources/VigiaCore/Samplers/GPUSampler.swift`:

```swift
import Foundation
import IOKit

public struct GPUMetrics: Sendable {
    /// Fracción de uso del dispositivo, entre 0 y 1.
    public let utilization: Double
    public let inUseMemoryBytes: UInt64
    public let allocatedMemoryBytes: UInt64
}

public struct GPUSampler {
    private static let statisticsKey = "PerformanceStatistics"
    private static let utilizationKey = "Device Utilization %"
    private static let inUseKey = "In use system memory"
    private static let allocatedKey = "Alloc system memory"

    public init() {}

    public func sample() throws -> GPUMetrics {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator
        )
        guard kr == KERN_SUCCESS else {
            throw SamplerError.machCall("IOServiceGetMatchingServices", kr)
        }
        defer { IOObjectRelease(iterator) }

        while case let servicio = IOIteratorNext(iterator), servicio != 0 {
            defer { IOObjectRelease(servicio) }
            guard let props = IORegistryEntryCreateCFProperty(
                servicio, Self.statisticsKey as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            guard let uso = props[Self.utilizationKey] as? Int else { continue }
            let enUso = props[Self.inUseKey] as? Int ?? 0
            let reservada = props[Self.allocatedKey] as? Int ?? 0

            return GPUMetrics(
                utilization: min(1, max(0, Double(uso) / 100)),
                inUseMemoryBytes: UInt64(max(0, enUso)),
                allocatedMemoryBytes: UInt64(max(0, reservada))
            )
        }
        throw SamplerError.registryKeyMissing(Self.statisticsKey)
    }
}
```

- [ ] **Step 4: Ejecutar**

Run: `swift test`
Expected: PASS, 10 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Samplers/GPUSampler.swift Tests/VigiaCoreTests/SamplerTests.swift
git commit -m "GPUSampler leyendo IOAccelerator sin privilegios"
```

---

### Task 9: PeripheralSampler con límite de tiempo

**Files:**
- Create: `Sources/VigiaCore/Samplers/PeripheralSampler.swift`
- Modify: `Tests/VigiaCoreTests/SamplerTests.swift`

`system_profiler` tarda segundos y a veces se cuelga. El límite de tiempo no es un adorno: sin él, la interfaz se congelaría.

- [ ] **Step 1: Escribir la prueba que falla**

Añadir a `Tests/VigiaCoreTests/SamplerTests.swift`:

```swift
@Test("PeripheralSampler respeta su límite de tiempo")
func perifericoRespetaLimite() {
    // Un comando que nunca termina debe abortarse, no colgar la prueba.
    let muestreador = PeripheralSampler(command: "/bin/sleep", arguments: ["30"], timeout: 0.5)
    let inicio = Date()
    #expect(throws: SamplerError.self) {
        _ = try muestreador.runCommand()
    }
    #expect(Date().timeIntervalSince(inicio) < 5)
}

@Test("PeripheralSampler extrae la batería del teclado Bluetooth")
func perifericoLeeBateria() throws {
    let muestreador = PeripheralSampler()
    let metricas = try muestreador.sample()
    // Puede no haber teclado Bluetooth conectado; lo que no puede es lanzar error.
    if let bateria = metricas.keyboardBatteryPercent {
        #expect(bateria >= 0 && bateria <= 100)
    }
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'PeripheralSampler' in scope`.

- [ ] **Step 3: Implementar**

Crear `Sources/VigiaCore/Samplers/PeripheralSampler.swift`:

```swift
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
```

- [ ] **Step 4: Ejecutar**

Run: `swift test`
Expected: PASS, 12 tests. `perifericoRespetaLimite` debe tardar menos de un segundo, no treinta.

- [ ] **Step 5: Commit**

```bash
git add Sources/VigiaCore/Samplers/PeripheralSampler.swift Tests/VigiaCoreTests/SamplerTests.swift
git commit -m "PeripheralSampler con limite de tiempo y busqueda recursiva de bateria"
```

---

### Task 10: SystemSnapshot y MetricsEngine

**Files:**
- Create: `Sources/VigiaCore/Snapshot/SystemSnapshot.swift`
- Create: `Sources/VigiaCore/Engine/MetricsEngine.swift`
- Test: `Tests/VigiaCoreTests/MetricsEngineTests.swift`

- [ ] **Step 1: Escribir la prueba que falla**

Crear `Tests/VigiaCoreTests/MetricsEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import VigiaCore

@Test("Un muestreador que falla no impide que los demás publiquen")
func falloAisladoNoTumbaElResto() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler(command: "/bin/false", arguments: [], timeout: 1)
    )
    await motor.refreshAll()
    let snapshot = await motor.snapshot

    // El de periféricos falla a propósito.
    #expect(snapshot.peripherals.value == nil)
    // Los demás deben seguir vivos.
    #expect(snapshot.memory.value != nil)
    #expect(snapshot.disk.value != nil)
}

@Test("Un valor previo se conserva marcado como viejo cuando el muestreo falla")
func valorPrevioSeConservaComoViejo() async throws {
    let motor = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler()
    )
    await motor.refreshPeripherals()
    let primero = await motor.snapshot.peripherals

    // Solo tiene sentido si la primera lectura funcionó.
    if primero.value != nil {
        await motor.markPeripheralsFailed(reason: "prueba")
        let segundo = await motor.snapshot.peripherals
        #expect(segundo.value != nil, "debe conservar el valor anterior")
        if case .stale = segundo {} else {
            Issue.record("se esperaba el estado viejo")
        }
    }
}
```

- [ ] **Step 2: Ejecutar y verificar que falla**

Run: `swift test`
Expected: FAIL — `cannot find 'MetricsEngine' in scope`.

- [ ] **Step 3: Implementar el snapshot**

Crear `Sources/VigiaCore/Snapshot/SystemSnapshot.swift`:

```swift
import Foundation

/// Lo que la vista consume. Inmutable: la vista nunca modifica nada.
public struct SystemSnapshot: Sendable {
    public var memory: MetricState<MemoryMetrics>
    public var cpu: MetricState<CPUMetrics>
    public var gpu: MetricState<GPUMetrics>
    public var disk: MetricState<DiskMetrics>
    public var peripherals: MetricState<PeripheralMetrics>
    public var pointer: MetricState<PointerHealth>
    public var capturedAt: Date

    public static var empty: SystemSnapshot {
        SystemSnapshot(
            memory: .unavailable(reason: "sin medir"),
            cpu: .unavailable(reason: "sin medir"),
            gpu: .unavailable(reason: "sin medir"),
            disk: .unavailable(reason: "sin medir"),
            peripherals: .unavailable(reason: "sin medir"),
            pointer: .unavailable(reason: "sin medir"),
            capturedAt: Date()
        )
    }
}
```

- [ ] **Step 4: Implementar el motor**

Crear `Sources/VigiaCore/Engine/MetricsEngine.swift`:

```swift
import Foundation

/// Coordina los muestreadores, aísla sus fallos y publica un snapshot.
///
/// Es un actor: los muestreadores se leen desde tareas distintas y el
/// snapshot se lee desde la interfaz.
public actor MetricsEngine {
    public private(set) var snapshot: SystemSnapshot = .empty

    private let memory: MemorySampler
    private let cpu: CPUSampler
    private let gpu: GPUSampler
    private let disk: DiskSampler
    private let peripherals: PeripheralSampler

    public init(
        memory: MemorySampler,
        cpu: CPUSampler,
        gpu: GPUSampler,
        disk: DiskSampler,
        peripherals: PeripheralSampler
    ) {
        self.memory = memory
        self.cpu = cpu
        self.gpu = gpu
        self.disk = disk
        self.peripherals = peripherals
    }

    /// Aplica un muestreo conservando el valor anterior si falla.
    private func apply<T>(
        _ estado: inout MetricState<T>,
        _ leer: () throws -> T?
    ) {
        do {
            if let valor = try leer() {
                estado = .ok(valor)
            }
            // Un nil no es un fallo: significa "aún no hay dato", como la
            // primera muestra de CPU. Se deja el estado como está.
        } catch {
            degrade(&estado, reason: String(describing: error))
        }
    }

    private func degrade<T>(_ estado: inout MetricState<T>, reason: String) {
        if let previo = estado.value {
            estado = .stale(previo, since: Date())
        } else {
            estado = .unavailable(reason: reason)
        }
    }

    public func refreshFast() {
        apply(&snapshot.memory) { try memory.sample() }
        apply(&snapshot.cpu) { try cpu.sample() }
        apply(&snapshot.gpu) { try gpu.sample() }
        snapshot.capturedAt = Date()
    }

    public func refreshDisk() {
        apply(&snapshot.disk) { try disk.sample() }
    }

    public func refreshPeripherals() {
        apply(&snapshot.peripherals) { try peripherals.sample() }
    }

    public func refreshAll() {
        refreshFast()
        refreshDisk()
        refreshPeripherals()
    }

    public func updatePointer(_ salud: PointerHealth) {
        snapshot.pointer = .ok(salud)
    }

    public func markPointerUnavailable(reason: String) {
        snapshot.pointer = .unavailable(reason: reason)
    }

    /// Expuesto para las pruebas de degradación.
    public func markPeripheralsFailed(reason: String) {
        degrade(&snapshot.peripherals, reason: reason)
    }

    /// Descarta el estado acumulado. Se llama al despertar del sueño: sin
    /// esto, la primera diferencia de CPU produce un pico falso.
    public func resetAccumulators() {
        cpu.reset()
    }
}
```

- [ ] **Step 5: Ejecutar**

Run: `swift test`
Expected: PASS, 14 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/VigiaCore/Snapshot Sources/VigiaCore/Engine Tests/VigiaCoreTests/MetricsEngineTests.swift
git commit -m "SystemSnapshot y MetricsEngine con aislamiento de fallos"
```

---

### Task 11: PointerHealthMonitor sobre IOHIDManager

**Files:**
- Create: `Sources/VigiaCore/Pointer/PointerHealthMonitor.swift`
- Modify: `Tests/VigiaCoreTests/GapDetectorTests.swift`

Esta tarea conecta el algoritmo ya probado con el hardware. No se prueba automáticamente el enganche a IOKit —requiere permiso y un mouse real—; se prueba a mano en el paso 5.

- [ ] **Step 1: Escribir la prueba del cierre de reinicio**

Añadir a `Tests/VigiaCoreTests/GapDetectorTests.swift`:

```swift
@Test("Reiniciar el detector borra los fallos acumulados")
func reiniciarBorraFallos() {
    let detector = GapDetector(declaredIntervalSeconds: 0.001)
    detector.record(PointerReport(timestamp: 0, moved: true))
    detector.record(PointerReport(timestamp: 0.080, moved: true))
    #expect(detector.health(now: 0.1).faults == 1)

    detector.reset()
    #expect(detector.health(now: 0.1).faults == 0)
}
```

- [ ] **Step 2: Ejecutar**

Run: `swift test`
Expected: PASS, 15 tests (`reset()` ya existe desde la Tarea 2).

- [ ] **Step 3: Implementar el monitor**

Crear `Sources/VigiaCore/Pointer/PointerHealthMonitor.swift`:

```swift
import Foundation
import IOKit
import IOKit.hid

/// Engancha el mouse por IOKit y alimenta un `GapDetector`.
///
/// Requiere el permiso de Monitoreo de Entrada. Si no lo hay, `start()`
/// devuelve `false` y la aplicación sigue funcionando sin esta métrica.
public final class PointerHealthMonitor {
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
        // El reloj de IOKit está en nanosegundos absolutos.
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
```

- [ ] **Step 4: Compilar**

Run: `swift build`
Expected: compila sin advertencias.

- [ ] **Step 5: Verificación manual con hardware**

Crear un ejecutable temporal de prueba y correrlo desde la terminal, moviendo el mouse:

```bash
cat > /tmp/pointercheck.swift <<'EOF'
import Foundation
import VigiaCore

let monitor = PointerHealthMonitor()
monitor.onHealthUpdate = { salud in
    print(String(format: "fallos: %d  hueco max: %.1f ms  intervalo: %.1f ms",
                 salud.faults, salud.maxGapSeconds * 1000,
                 salud.expectedIntervalSeconds * 1000))
}
guard monitor.start() else {
    print("no se pudo abrir el gestor HID: falta el permiso de Monitoreo de Entrada")
    exit(1)
}
RunLoop.main.run()
EOF
swift build
swiftc -I .build/debug -L .build/debug -lVigiaCore /tmp/pointercheck.swift -o /tmp/pointercheck
/tmp/pointercheck
```

Expected: al mover el mouse en círculos durante veinte segundos aparece una línea por segundo. En el equipo objetivo, con el dongle en el hub del dock, se esperan fallos ocasionales; al pasar el dongle a un puerto directo, deberían bajar. Si la primera ejecución imprime el mensaje de permiso, concederlo en Ajustes del Sistema → Privacidad y seguridad → Monitoreo de entrada y repetir.

- [ ] **Step 6: Commit**

```bash
git add Sources/VigiaCore/Pointer/PointerHealthMonitor.swift Tests/VigiaCoreTests/GapDetectorTests.swift
git commit -m "PointerHealthMonitor enganchando el mouse por IOHIDManager"
```

---

### Task 12: Proyecto de app y panel flotante

**Files:**
- Create: `App/Vigia/VigiaApp.swift`
- Create: `App/Vigia/HUDPanel.swift`
- Create: `App/Vigia/Info.plist`

A partir de aquí se trabaja en Xcode. Crear el proyecto con: App de macOS, interfaz SwiftUI, nombre `Vigia`, ubicación `App/`. Después, en el proyecto, añadir el paquete local: File → Add Package Dependencies → Add Local → seleccionar la raíz del repositorio → añadir `VigiaCore` al target.

- [ ] **Step 1: Configurar Info.plist**

En `App/Vigia/Info.plist` añadir estas dos claves. `LSUIElement` es lo que quita la app del Dock y de Cmd-Tab:

```xml
<key>LSUIElement</key>
<true/>
<key>NSInputMonitoringUsageDescription</key>
<string>Vigía mide los tiempos entre reportes del mouse para detectar pérdidas de señal del receptor inalámbrico. No registra qué teclas pulsas ni a dónde apuntas.</string>
```

- [ ] **Step 2: Crear el panel flotante**

Crear `App/Vigia/HUDPanel.swift`:

```swift
import AppKit
import SwiftUI

/// Panel que flota sobre las demás ventanas sin robar el foco.
final class HUDPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 220),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        // Flota por encima del resto de ventanas.
        level = .floating
        // Sigue visible al cambiar de espacio y en pantalla completa.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // No se cierra al perder el foco.
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: content)
    }

    // Un panel sin barra de título debe poder ser la ventana principal
    // para recibir clics, pero nunca la ventana clave.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 3: Crear el punto de entrada con una vista provisional**

`HUDModel` y `HUDView` llegan en la Tarea 13. Para que esta tarea compile y se pueda ver el panel funcionando por sí solo, se usa una vista provisional que la Tarea 13 sustituye.

Crear `App/Vigia/VigiaApp.swift`:

```swift
import SwiftUI
import AppKit
import VigiaCore

@main
struct VigiaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // La interfaz vive en el NSPanel, no en una escena de SwiftUI.
        Settings { EmptyView() }
    }
}

/// Provisional: la Tarea 13 la reemplaza por `HUDView`.
struct PlaceholderView: View {
    var body: some View {
        Text("Vigía")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: HUDPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = HUDPanel(content: PlaceholderView())
        panel.setFrameOrigin(NSPoint(x: 60, y: 60))
        panel.orderFrontRegardless()
        self.panel = panel
    }
}
```

- [ ] **Step 4: Compilar y ejecutar**

Run: compilar y ejecutar desde Xcode (Cmd-R).
Expected: aparece un panel con la palabra "Vigía" flotando sobre las demás ventanas, sin icono en el Dock, arrastrable, y que sigue visible al cambiar de espacio. Todavía no muestra datos: eso llega en la Tarea 13.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "Proyecto de app con panel flotante sin Dock"
```

---

### Task 13: Modelo de la interfaz y vista

**Files:**
- Create: `App/Vigia/HUDModel.swift`
- Create: `App/Vigia/HUDView.swift`

- [ ] **Step 1: Crear el modelo que conecta motor y vista**

Crear `App/Vigia/HUDModel.swift`:

```swift
import Foundation
import SwiftUI
import AppKit
import VigiaCore

/// Une el motor con la vista y gobierna los ritmos de refresco.
@MainActor
final class HUDModel: ObservableObject {
    @Published private(set) var snapshot: SystemSnapshot = .empty
    @Published private(set) var pointerPermissionDenied = false

    private let engine = MetricsEngine(
        memory: MemorySampler(),
        cpu: CPUSampler(),
        gpu: GPUSampler(),
        disk: DiskSampler(),
        peripherals: PeripheralSampler()
    )
    private let pointer = PointerHealthMonitor()
    private var tareas: [Task<Void, Never>] = []

    private static let claveOrigen = "hud.origin"

    var savedOrigin: NSPoint {
        let guardado = UserDefaults.standard.string(forKey: Self.claveOrigen)
        return guardado.map { NSPointFromString($0) } ?? NSPoint(x: 60, y: 60)
    }

    func saveOrigin(_ punto: NSPoint) {
        UserDefaults.standard.set(NSStringFromPoint(punto), forKey: Self.claveOrigen)
    }

    func start() {
        // Cada bucle usa `[weak self]`: el modelo vive mientras viva la app,
        // pero una referencia fuerte desde una tarea que nunca termina
        // impediría liberarlo al cerrar.
        // Ritmo rápido: CPU, memoria y GPU cada segundo.
        tareas.append(Task { [weak self, engine] in
            while !Task.isCancelled {
                await engine.refreshFast()
                await self?.publish()
                try? await Task.sleep(for: .seconds(1))
            }
        })
        // Disco cada treinta segundos.
        tareas.append(Task { [weak self, engine] in
            while !Task.isCancelled {
                await engine.refreshDisk()
                await self?.publish()
                try? await Task.sleep(for: .seconds(30))
            }
        })
        // Periféricos cada cinco minutos: system_profiler es caro.
        tareas.append(Task { [weak self, engine] in
            while !Task.isCancelled {
                await engine.refreshPeripherals()
                await self?.publish()
                try? await Task.sleep(for: .seconds(300))
            }
        })

        pointer.onHealthUpdate = { [engine] salud in
            Task { await engine.updatePointer(salud) }
        }
        if !pointer.start() {
            pointerPermissionDenied = true
            Task { await engine.markPointerUnavailable(reason: "permiso requerido") }
        }
    }

    func stop() {
        tareas.forEach { $0.cancel() }
        tareas.removeAll()
        pointer.stop()
    }

    func handleWake() {
        Task {
            await engine.resetAccumulators()
            pointer.reset()
        }
    }

    func openInputMonitoringSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    private func publish() async {
        snapshot = await engine.snapshot
    }
}
```

- [ ] **Step 2: Crear la vista**

Crear `App/Vigia/HUDView.swift`:

```swift
import SwiftUI
import AppKit
import VigiaCore

/// Dibuja el snapshot. Sin lógica: si aquí aparece un cálculo, va en el motor.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            barra("CPU", fraccion: model.snapshot.cpu.value?.totalUsage,
                  detalle: model.snapshot.cpu.value.map {
                      String(format: "P %.0f%%  E %.0f%%",
                             $0.performanceUsage * 100, $0.efficiencyUsage * 100)
                  })
            barra("RAM", fraccion: model.snapshot.memory.value?.usedFraction,
                  detalle: model.snapshot.memory.value.map {
                      String(format: "swap %.1f GB", Double($0.swapUsedBytes) / 1e9)
                  })
            barra("GPU", fraccion: model.snapshot.gpu.value?.utilization,
                  detalle: model.snapshot.gpu.value.map {
                      String(format: "%.0f MB", Double($0.inUseMemoryBytes) / 1e6)
                  })
            barra("SSD", fraccion: model.snapshot.disk.value?.usedFraction,
                  detalle: model.snapshot.disk.value.map {
                      String(format: "%.0f GB libres", Double($0.freeBytes) / 1e9)
                  })

            Divider()
            perifericos
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func barra(_ titulo: String, fraccion: Double?, detalle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(titulo)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
                Text(fraccion.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
            }
            ProgressView(value: fraccion ?? 0)
                .progressViewStyle(.linear)
                .tint(color(for: fraccion))
            if let detalle {
                Text(detalle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Verde por debajo del 70%, ámbar hasta el 90%, rojo por encima.
    private func color(for fraccion: Double?) -> Color {
        guard let fraccion else { return .gray }
        if fraccion > 0.9 { return .red }
        if fraccion > 0.7 { return .orange }
        return .green
    }

    @ViewBuilder
    private var perifericos: some View {
        if model.pointerPermissionDenied {
            Button("Activar detección de trabones") {
                model.openInputMonitoringSettings()
            }
            .font(.system(size: 10))
        } else if let salud = model.snapshot.pointer.value {
            HStack {
                Text("Mouse").font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
                Text(salud.faults == 0
                     ? "estable"
                     : String(format: "%d fallos · %.0f ms", salud.faults,
                              salud.maxGapSeconds * 1000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(salud.faults == 0 ? Color.green : Color.orange)
            }
        }

        if let bateria = model.snapshot.peripherals.value?.keyboardBatteryPercent {
            HStack {
                Text("Teclado").font(.system(size: 11, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(bateria)%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(bateria < 20 ? Color.red : Color.secondary)
            }
        }
    }
}
```

- [ ] **Step 3: Compilar y ejecutar**

Run: Cmd-R en Xcode.
Expected: el panel muestra cuatro barras con datos reales que cambian cada segundo. Comparar la cifra de RAM contra `vm_stat` y la de disco contra `df -h` en la terminal: deben coincidir dentro de un margen razonable.

- [ ] **Step 4: Conceder el permiso y verificar el mouse**

Al primer arranque, el panel muestra el botón "Activar detección de trabones". Pulsarlo, conceder el permiso, reiniciar la app.
Expected: la fila del mouse pasa a mostrar "estable" y, al mover el mouse durante un minuto con el dongle en el hub del dock, aparecen fallos ocasionales.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "Modelo y vista del panel con datos reales"
```

---

### Task 14: Ajustes persistidos y arranque con el sistema

**Files:**
- Create: `App/Vigia/SettingsStore.swift`
- Modify: `App/Vigia/HUDModel.swift`
- Modify: `App/Vigia/HUDView.swift`

- [ ] **Step 1: Crear el almacén de ajustes**

Crear `App/Vigia/SettingsStore.swift`:

```swift
import Foundation
import ServiceManagement

/// Las métricas que el panel puede mostrar u ocultar.
enum MetricKind: String, CaseIterable, Identifiable {
    case cpu, memory, gpu, disk, pointer, keyboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memoria"
        case .gpu: return "GPU"
        case .disk: return "Disco"
        case .pointer: return "Mouse"
        case .keyboard: return "Teclado"
        }
    }
}

/// Ajustes que sobreviven al reinicio.
final class SettingsStore: ObservableObject {
    @Published var opacity: Double {
        didSet { UserDefaults.standard.set(opacity, forKey: "hud.opacity") }
    }
    @Published var launchAtLogin: Bool {
        didSet { aplicarArranque() }
    }
    /// Métricas visibles. Se guarda la lista de las ocultas, para que una
    /// métrica nueva en una versión futura aparezca por omisión.
    @Published var hidden: Set<MetricKind> {
        didSet {
            UserDefaults.standard.set(hidden.map(\.rawValue), forKey: "hud.hidden")
        }
    }

    init() {
        let guardada = UserDefaults.standard.double(forKey: "hud.opacity")
        // Un valor de cero significa que nunca se ha guardado.
        opacity = guardada == 0 ? 0.95 : guardada
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let ocultas = UserDefaults.standard.stringArray(forKey: "hud.hidden") ?? []
        hidden = Set(ocultas.compactMap(MetricKind.init(rawValue:)))
    }

    func isVisible(_ metrica: MetricKind) -> Bool {
        !hidden.contains(metrica)
    }

    func toggle(_ metrica: MetricKind) {
        if hidden.contains(metrica) {
            hidden.remove(metrica)
        } else {
            hidden.insert(metrica)
        }
    }

    private func aplicarArranque() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Si el sistema lo rechaza, reflejar el estado real en la casilla.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
```

- [ ] **Step 2: Conectar la opacidad a la vista**

En `App/Vigia/HUDView.swift`, añadir la propiedad al principio de la estructura:

```swift
    @StateObject private var settings = SettingsStore()
```

y cambiar el modificador `.background(...)` del `VStack` principal por estos dos:

```swift
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(settings.opacity)
```

- [ ] **Step 3: Añadir el menú contextual**

En `App/Vigia/HUDView.swift`, añadir después de `.opacity(settings.opacity)`:

```swift
        .contextMenu {
            Menu("Mostrar") {
                ForEach(MetricKind.allCases) { metrica in
                    Button {
                        settings.toggle(metrica)
                    } label: {
                        // La palomita indica que la métrica está visible.
                        Label(metrica.label,
                              systemImage: settings.isVisible(metrica) ? "checkmark" : "")
                    }
                }
            }
            Menu("Opacidad") {
                Button("100%") { settings.opacity = 1.0 }
                Button("95%")  { settings.opacity = 0.95 }
                Button("80%")  { settings.opacity = 0.8 }
                Button("60%")  { settings.opacity = 0.6 }
            }
            Toggle("Arrancar con el sistema", isOn: $settings.launchAtLogin)
            Divider()
            Button("Salir de Vigía") { NSApplication.shared.terminate(nil) }
        }
```

- [ ] **Step 4: Respetar la visibilidad en la vista**

En `App/Vigia/HUDView.swift`, envolver cada fila del `VStack` principal con su condición. Reemplazar las cuatro llamadas a `barra(...)` por:

```swift
            if settings.isVisible(.cpu) {
                barra("CPU", fraccion: model.snapshot.cpu.value?.totalUsage,
                      detalle: model.snapshot.cpu.value.map {
                          String(format: "P %.0f%%  E %.0f%%",
                                 $0.performanceUsage * 100, $0.efficiencyUsage * 100)
                      })
            }
            if settings.isVisible(.memory) {
                barra("RAM", fraccion: model.snapshot.memory.value?.usedFraction,
                      detalle: model.snapshot.memory.value.map {
                          String(format: "swap %.1f GB", Double($0.swapUsedBytes) / 1e9)
                      })
            }
            if settings.isVisible(.gpu) {
                barra("GPU", fraccion: model.snapshot.gpu.value?.utilization,
                      detalle: model.snapshot.gpu.value.map {
                          String(format: "%.0f MB", Double($0.inUseMemoryBytes) / 1e6)
                      })
            }
            if settings.isVisible(.disk) {
                barra("SSD", fraccion: model.snapshot.disk.value?.usedFraction,
                      detalle: model.snapshot.disk.value.map {
                          String(format: "%.0f GB libres", Double($0.freeBytes) / 1e9)
                      })
            }
```

En la propiedad `perifericos`, cambiar la primera condición por `if model.pointerPermissionDenied, settings.isVisible(.pointer) {`, la segunda por `} else if settings.isVisible(.pointer), let salud = model.snapshot.pointer.value {`, y la del teclado por `if settings.isVisible(.keyboard), let bateria = model.snapshot.peripherals.value?.keyboardBatteryPercent {`.

Además, para que el panel se encoja al ocultar métricas, cambiar el modificador de tamaño del `VStack` de `.frame(width: 260, alignment: .leading)` a:

```swift
        .frame(width: 260, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
```

- [ ] **Step 5: Verificar**

Run: Cmd-R en Xcode.
Expected: clic derecho sobre el panel abre el menú; ocultar una métrica la quita al instante y el panel se encoge; cambiar la opacidad se ve al instante; ambas cosas sobreviven al reinicio de la app; activar el arranque con el sistema hace aparecer Vigía en Ajustes → General → Ítems de inicio.

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "Ajustes persistidos: opacidad y arranque con el sistema"
```

---

### Task 15: Verificación de extremo a extremo

**Files:** ninguno nuevo — es una tarea de comprobación.

- [ ] **Step 1: Correr toda la batería de pruebas**

Run: `swift test`
Expected: PASS, 15 tests, sin advertencias.

- [ ] **Step 2: Contrastar cada cifra contra el sistema**

Con la app abierta, ejecutar en la terminal y comparar:

```bash
vm_stat | grep -E "Pages free|occupied by compressor"
sysctl vm.swapusage
df -h /System/Volumes/Data
ioreg -r -d 1 -c IOAccelerator | grep -o '"Device Utilization %"=[0-9]*'
```

Expected: cada valor del panel coincide con el del sistema dentro de un margen de un segundo de desfase.

- [ ] **Step 3: Probar la degradación ante fallos**

Renombrar temporalmente `system_profiler` no es viable en un sistema protegido, así que la prueba es la del motor (Tarea 10) más esta comprobación manual: desconectar el receptor del mouse durante diez segundos y volver a conectarlo.
Expected: la fila del mouse deja de actualizarse pero el resto del panel sigue vivo; al reconectar, las estadísticas se reinician solas sin reiniciar la app.

- [ ] **Step 4: Probar el ciclo de sueño**

Poner el Mac a dormir, esperar un minuto, despertarlo.
Expected: las cifras de CPU no muestran un pico falso del 100% en la primera lectura tras despertar.

- [ ] **Step 5: Medir el consumo de la propia app**

Run: `ps aux | grep "[V]igia" | awk '{printf "cpu:%s%%  mem:%.0f MB\n", $3, $6/1024}'`
Expected: por debajo de 60 MB de memoria y 2% de CPU sostenido. Si excede, revisar el ritmo de publicación del monitor del mouse: es el candidato más probable.

- [ ] **Step 6: Commit final**

```bash
git add -A
git commit -m "Verificacion de extremo a extremo de Vigia"
```

---

## Cobertura del spec

| Requisito del spec | Tarea |
|---|---|
| Panel flotante, sin Dock, no roba foco | 12 |
| `CPUSampler` con reparto P/E | 7 |
| `MemorySampler` | 5 |
| `GPUSampler` | 8 |
| `DiskSampler` | 6 |
| `PeripheralSampler` con límite de tiempo | 9 |
| `PointerHealthMonitor` | 11 |
| Detector de trabones (pasos 1–6 del spec) | 2, 3, 4 |
| Ritmo de interfaz desacoplado del de medición | 11 (paso 3), 13 |
| Tres estados por métrica | 1, 10 |
| Aislamiento de fallos entre muestreadores | 10 |
| `system_profiler` fuera del hilo principal con límite | 9, 13 |
| Reenganche tras desconexión del mouse | 11, 15 |
| Descarte de acumuladores al despertar | 10, 12, 13, 15 |
| Permiso opcional, la app sigue viva sin él | 11, 13 |
| Ajustes: posición del panel | 13 |
| Ajustes: opacidad | 14 |
| Ajustes: qué métricas mostrar | 14 |
| Ajustes: arranque con el sistema | 14 |
| Pruebas sin hardware del detector | 2, 3, 4 |
