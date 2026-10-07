import CoreWLAN
import Foundation

public enum AssociateOutcome {
    case connected(via: String)
    case failed(String)
}

/// Joins a network: CoreWLAN first, `networksetup` as the fallback, then a
/// bounded wait for the association to actually take effect.
public enum Associator {
    public static func find(network entry: NetworkEntry, interfaceName: String?) -> CWNetwork? {
        guard let iface = Scanner.interface(named: interfaceName) else { return nil }
        let scanned = (try? iface.scanForNetworks(withName: nil)) ?? []
        if let bssid = entry.bssid {
            if let match = scanned.first(where: { $0.bssid?.lowercased() == bssid.lowercased() }) {
                return match
            }
        }
        if let ssid = entry.ssid {
            let sameName = scanned.filter { $0.ssid == ssid }
            if let channel = entry.channel,
               let match = sameName.first(where: { $0.wlanChannel?.channelNumber == channel }) {
                return match
            }
            if let match = sameName.max(by: { $0.rssiValue < $1.rssiValue }) { return match }
        }
        return entry.ref
    }

    public static func connect(
        entry: NetworkEntry,
        password: String?,
        interfaceName: String?,
        timeout: TimeInterval = 20,
        progress: (String) -> Void
    ) -> AssociateOutcome {
        guard let iface = Scanner.interface(named: interfaceName) else {
            return .failed("no Wi-Fi interface available")
        }
        let name = iface.interfaceName ?? "wi-fi"
        guard iface.powerOn() else { return .failed("Wi-Fi is turned off on \(name)") }

        let label = entry.displaySSID
        progress("Looking for \(label)...")
        guard let target = find(network: entry, interfaceName: interfaceName) else {
            return .failed("\(label) is not in range of \(name) right now")
        }

        progress("Associating with \(label)...")
        var coreWLANError: String?
        do {
            try iface.associate(to: target, password: password ?? "")
        } catch {
            coreWLANError = error.localizedDescription
        }

        if verify(iface: iface, entry: entry, timeout: timeout, progress: progress) {
            return .connected(via: "CoreWLAN")
        }

        // Fallback: networksetup still works on macOS 15 and can use the
        // credential macOS stored for a saved network.
        if let ssid = entry.ssid {
            progress("Retrying with networksetup...")
            if let result = SavedNetworks.setNetwork(interfaceName: name, ssid: ssid, password: password),
               result.status == 0 {
                if verify(iface: iface, entry: entry, timeout: timeout, progress: progress) {
                    return .connected(via: "networksetup")
                }
            }
        }

        if let coreWLANError {
            return .failed("could not join \(label): \(coreWLANError)")
        }
        return .failed("could not join \(label); the interface never reported the association")
    }

    /// Waits for the interface to report the target network.
    private static func verify(
        iface: CWInterface,
        entry: NetworkEntry,
        timeout: TimeInterval,
        progress: (String) -> Void
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastReport = Date.distantPast
        while Date() < deadline {
            if matches(iface: iface, entry: entry) { return true }
            if Date().timeIntervalSince(lastReport) > 3 {
                let elapsed = Int(timeout - max(0, deadline.timeIntervalSinceNow))
                progress("Waiting for \(entry.displaySSID) (\(elapsed)s)...")
                lastReport = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return matches(iface: iface, entry: entry)
    }

    private static func matches(iface: CWInterface, entry: NetworkEntry) -> Bool {
        if let bssid = entry.bssid, let current = iface.bssid() {
            return current.lowercased() == bssid.lowercased()
        }
        if let ssid = entry.ssid, let current = iface.ssid() {
            return current == ssid
        }
        return false
    }
}
