import Foundation

/// Reports `ProcessInfo.thermalState` and pushes changes as they happen (§5).
///
/// iOS's four states map one-to-one onto the pipeline's, which is where the
/// pipeline's four came from. Android's five-step scale is the one that needs
/// folding — see `ThermalMonitor.kt`.
final class ThermalMonitor {

    private var observer: NSObjectProtocol?

    var current: PlatformThermalState { ThermalMonitor.map(ProcessInfo.processInfo.thermalState) }

    func start(onChanged: @escaping (PlatformThermalState) -> Void) {
        stop()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChanged(ThermalMonitor.map(ProcessInfo.processInfo.thermalState))
        }
    }

    func stop() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private static func map(_ state: ProcessInfo.ThermalState) -> PlatformThermalState {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
