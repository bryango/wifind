import CoreLocation
import Foundation

/// CoreLocation gate for Wi-Fi scanning.
///
/// Since macOS 13, `CWNetwork.ssid` is nil for every scan result unless the
/// process is allowed to use Location Services. The prompt only appears for a
/// process that has a usage-description string (an app bundle), so a bare
/// binary usually inherits the terminal's authorization; `wifind doctor`
/// reports which one applied.
public final class LocationGate: NSObject, CLLocationManagerDelegate {
    public static let shared = LocationGate()

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var changed = false

    public override init() {
        super.init()
        manager.delegate = self
    }

    public var status: CLAuthorizationStatus { manager.authorizationStatus }

    public var statusLabel: String { LocationGate.label(for: status) }

    public static func label(for status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorized (always)"
        @unknown default: return "unknown"
        }
    }

    public var isAuthorized: Bool {
        status == .authorizedAlways
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        lock.lock()
        changed = true
        lock.unlock()
    }

    /// Requests authorization if the state is still `notDetermined` and waits
    /// (bounded by `timeout`) for the user to answer. Returns the status after
    /// the wait.
    @discardableResult
    public func requestIfNeeded(timeout: TimeInterval = 30) -> CLAuthorizationStatus {
        guard status == .notDetermined else { return status }
        manager.requestAlwaysAuthorization()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status != .notDetermined { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return status
    }
}

/// Authorization guidance shown in the UI and in `doctor`.
public enum LocationAdvice {
    public static func fix(for status: CLAuthorizationStatus, bundled: Bool, parent: String?) -> String {
        switch status {
        case .authorizedAlways:
            return "Location Services access is granted."
        case .notDetermined:
            return "Location Services access has not been requested yet; a scan should trigger the prompt."
        case .denied, .restricted:
            let target = bundled
                ? "wifind"
                : (parent.map { "\"\($0)\"" } ?? "your terminal")
            return "Location Services is off for \(target). Enable it in System Settings > "
                + "Privacy & Security > Location Services, then run again."
        @unknown default:
            return "Location Services status is unknown."
        }
    }
}
