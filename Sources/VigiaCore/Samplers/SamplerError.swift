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
