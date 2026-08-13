import Foundation
import Darwin

/// Una aplicación y lo que consume, sumando todos sus procesos.
public struct ProcessGroup: Sendable, Equatable, Identifiable {
    /// Ruta del paquete, o del binario si no hay paquete. Ver `ProcessIdentity`.
    public let id: String
    public let name: String
    /// Todos los procesos del grupo, el principal primero.
    public let pids: [Int32]
    /// A quién mandarle la señal para cerrar el grupo entero.
    public let mainPID: Int32
    public let residentBytes: UInt64
    /// Fracción de la capacidad **total** de la máquina, entre 0 y 1, para que
    /// se pueda comparar con `CPUMetrics.totalUsage` sin traducir nada.
    ///
    /// `nil` en la primera muestra: el uso de CPU es una diferencia entre dos
    /// lecturas, así que la primera no puede saberlo. Un cero ahí sería mentira.
    public let cpuFraction: Double?
    /// Si es `true`, la interfaz no debe ofrecer ninguna acción sobre él.
    public let isProtected: Bool

    public init(
        id: String,
        name: String,
        pids: [Int32],
        mainPID: Int32,
        residentBytes: UInt64,
        cpuFraction: Double?,
        isProtected: Bool
    ) {
        self.id = id
        self.name = name
        self.pids = pids
        self.mainPID = mainPID
        self.residentBytes = residentBytes
        self.cpuFraction = cpuFraction
        self.isProtected = isProtected
    }
}

/// Aísla un `ProcessSampler` para poder usarlo desde la interfaz.
///
/// Recorrer seiscientos procesos y leer tres estructuras de cada uno tarda
/// decenas de milisegundos: lo bastante para que el panel diera tirones si
/// corriera en el hilo principal. El muestreador tampoco es seguro para uso
/// concurrente —guarda la muestra anterior—, y un actor resuelve las dos cosas
/// a la vez.
public actor ProcessMonitor {
    private let sampler: ProcessSampler

    public init(coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        sampler = ProcessSampler(coreCount: coreCount)
    }

    public func sample() -> [ProcessGroup] { sampler.sample() }

    public func reset() { sampler.reset() }
}

/// Enumera los procesos y calcula cuánta CPU consume cada uno.
///
/// No es seguro para uso concurrente: guarda la muestra anterior, igual que
/// `CPUSampler`.
///
/// **Solo ve los procesos del usuario.** `proc_pidinfo` niega la información de
/// los procesos ajenos sin privilegios de root, así que de unos 600 procesos se
/// leen unos 400. No es una limitación que valga la pena resolver: los que
/// faltan son del sistema, y `ProcessGuard` prohibiría actuar sobre ellos de
/// todos modos.
public final class ProcessSampler {
    /// Lo que hace falta recordar de un proceso para calcular su diferencia.
    private struct Muestra {
        let cpuTicks: UInt64
        /// Distingue un proceso nuevo que heredó un pid recién liberado. Sin
        /// esto, su tiempo acumulado —que arranca de cero— daría una
        /// diferencia negativa, o peor, un pico enorme al revés.
        let startedAt: UInt64
    }

    private var previas: [Int32: Muestra] = [:]
    private var muestreadaEn: Date?
    private let coreCount: Int
    private let nanosPorTick: Double

    public init(coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        // Un cero aquí volvería infinita cualquier fracción de CPU.
        self.coreCount = max(1, coreCount)

        // `pti_total_user` y `pti_total_system` vienen en ticks de Mach, no en
        // nanosegundos, aunque `proc_info.h` los llame "total time" a secas. La
        // diferencia no es cosmética: en este Apple Silicon un tick son 41,67 ns
        // —numerador 125, denominador 3—, así que confundirlos hunde toda
        // medición de CPU a cero y la lista de culpables no acusa a nadie.
        // El factor es propiedad del hardware y no cambia en marcha.
        var base = mach_timebase_info_data_t()
        nanosPorTick = mach_timebase_info(&base) == KERN_SUCCESS && base.denom > 0
            ? Double(base.numer) / Double(base.denom)
            : 1
    }

    /// Descarta el historial. Obligatorio al despertar del sueño: el tiempo de
    /// pared avanzó horas mientras los contadores de CPU no, y la diferencia
    /// saldría absurdamente baja.
    public func reset() {
        previas.removeAll()
        muestreadaEn = nil
    }

    /// Lee todos los procesos legibles y los agrupa por aplicación.
    ///
    /// - Returns: los grupos ordenados de mayor a menor consumo de memoria.
    public func sample(now: Date = Date()) -> [ProcessGroup] {
        let transcurrido = muestreadaEn.map { now.timeIntervalSince($0) }
        var acumulados: [String: Acumulador] = [:]
        var nuevas: [Int32: Muestra] = [:]

        for pid in pidsActivos() {
            guard let info = taskInfo(pid), let ruta = executablePath(pid) else { continue }

            let arranque = startTime(pid) ?? 0
            let cpuTicks = info.pti_total_user + info.pti_total_system
            nuevas[pid] = Muestra(cpuTicks: cpuTicks, startedAt: arranque)

            // Solo cuenta si el pid designa al mismo proceso que la vez
            // anterior; si no, no hay diferencia que calcular.
            var ticksUsados: UInt64?
            if let previa = previas[pid], previa.startedAt == arranque,
               cpuTicks >= previa.cpuTicks {
                ticksUsados = cpuTicks - previa.cpuTicks
            }

            let clave = ProcessIdentity.groupKey(forExecutablePath: ruta)
            var acumulador = acumulados[clave] ?? Acumulador(
                nombre: ProcessIdentity.displayName(forExecutablePath: ruta),
                protegido: false
            )
            acumulador.agregar(
                pid: pid,
                esPrincipal: ProcessIdentity.isMainExecutable(ofApp: ruta),
                residente: info.pti_resident_size,
                ticks: ticksUsados,
                protegido: ProcessGuard.isProtected(path: ruta, pid: pid)
            )
            acumulados[clave] = acumulador
        }

        previas = nuevas
        muestreadaEn = now

        return acumulados
            .map {
                $0.value.grupo(
                    id: $0.key,
                    transcurrido: transcurrido,
                    nucleos: coreCount,
                    nanosPorTick: nanosPorTick
                )
            }
            .sorted { $0.residentBytes > $1.residentBytes }
    }

    /// Suma los procesos de una misma aplicación mientras se recorren.
    private struct Acumulador {
        let nombre: String
        var protegido: Bool
        var pids: [Int32] = []
        var principal: Int32?
        var residente: UInt64 = 0
        var ticks: UInt64 = 0
        /// Si ningún proceso del grupo aportó diferencia, no hay dato de CPU
        /// que dar. Sumar ceros lo haría parecer inactivo.
        var huboDiferencia = false

        mutating func agregar(
            pid: Int32,
            esPrincipal: Bool,
            residente bytes: UInt64,
            ticks usados: UInt64?,
            protegido esProtegido: Bool
        ) {
            pids.append(pid)
            residente += bytes
            if let usados {
                ticks += usados
                huboDiferencia = true
            }
            // El grupo se protege entero si cualquiera de sus procesos lo está:
            // cerrar la aplicación se lleva por delante a todos sus ayudantes.
            if esProtegido { protegido = true }
            // Entre varios candidatos gana el de pid más bajo, que en una
            // aplicación es el que arrancó primero: el proceso padre.
            if esPrincipal, principal == nil || pid < principal! { principal = pid }
        }

        func grupo(
            id: String,
            transcurrido: TimeInterval?,
            nucleos: Int,
            nanosPorTick: Double
        ) -> ProcessGroup {
            var fraccion: Double?
            if huboDiferencia, let transcurrido, transcurrido > 0 {
                let capacidad = transcurrido * Double(nucleos) * 1_000_000_000
                // Puede pasarse de 1 por redondeo entre las dos lecturas.
                fraccion = min(1, Double(ticks) * nanosPorTick / capacidad)
            }
            let elegido = principal ?? pids.min() ?? 0
            return ProcessGroup(
                id: id,
                name: nombre,
                pids: [elegido] + pids.filter { $0 != elegido }.sorted(),
                mainPID: elegido,
                residentBytes: residente,
                cpuFraction: fraccion,
                isProtected: protegido
            )
        }
    }

    // MARK: - Envoltorios de libproc

    private func pidsActivos() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size)
        let escritos = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bytes)
        guard escritos > 0 else { return [] }
        // El sistema puede devolver menos de lo que cabe: los procesos que
        // murieron entre las dos llamadas dejan ceros al final.
        return pids.prefix(Int(escritos) / MemoryLayout<Int32>.size).filter { $0 > 0 }
    }

    private func taskInfo(_ pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let tam = Int32(MemoryLayout<proc_taskinfo>.size)
        // Un resultado corto significa que no hubo permiso o que el proceso ya
        // murió; en ambos casos la estructura queda a medio llenar.
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, tam) == tam else { return nil }
        return info
    }

    private func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let tam = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, tam) == tam else { return nil }
        return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
    }

    /// `PROC_PIDPATHINFO_MAXSIZE` de `<libproc.h>`, que es una macro y por eso
    /// no llega a Swift. Vale `4 * MAXPATHLEN`, y `proc_pidpath` rechaza con
    /// `ENOMEM` cualquier búfer más pequeño.
    private static let maxPathSize = 4 * 1024

    private func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Self.maxPathSize)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let ruta = String(cString: buffer)
        return ruta.isEmpty ? nil : ruta
    }
}
