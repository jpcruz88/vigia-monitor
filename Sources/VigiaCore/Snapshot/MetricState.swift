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
