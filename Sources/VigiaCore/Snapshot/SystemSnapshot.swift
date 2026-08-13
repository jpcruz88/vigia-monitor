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
