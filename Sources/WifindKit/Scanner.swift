import CoreWLAN
import Foundation

public enum ScanFailure: Error, CustomStringConvertible {
    case noInterface(String?)
    case poweredOff(String)
    case scanFailed(String)

    public var description: String {
        switch self {
        case .noInterface(let name):
            return name.map { "no Wi-Fi interface named \($0)" } ?? "no Wi-Fi interface available"
        case .poweredOff(let name):
            return "Wi-Fi is turned off on \(name)"
        case .scanFailed(let message):
            return "scan failed: \(message)"
        }
    }
}

/// Everything one scan produced, including the counters the UI and `doctor` 
/// use to explain a degraded result.
public enum ScanRoute: String, Sendable {
    /// Scanned by this process.
    case local
    /// Scanned by the app bundle launched through LaunchServices.
    case helper
}

public struct ScanOutcome {
    public var entries: [NetworkEntry]
    public var rawCount: Int
    public var duration: TimeInterval
    public var ssidVisible: Int
    public var bssidVisible: Int
    public var interfaceName: String?
    public var notes: [String]
    /// Which process produced this result.
    public var route: ScanRoute = .local
    /// Path of the bundle that served it, when `route` is `.helper`.
    public var helperBundle: String?
}

public enum Scanner {
    // MARK: interface helpers

    public static func interfaceNames() -> [String] {
        (CWWiFiClient.shared().interfaces() ?? []).compactMap { $0.interfaceName }
    }

    public static func interface(named name: String?) -> CWInterface? {
        if let name {
            return (CWWiFiClient.shared().interfaces() ?? []).first { $0.interfaceName == name }
        }
        if let def = CWWiFiClient.shared().interface(), let _ = def.interfaceName { return def }
        return (CWWiFiClient.shared().interfaces() ?? []).first
    }

    public static func interfaceDescription(named name: String?) -> [(name: String, powerOn: Bool, serviceActive: Bool)] {
        (CWWiFiClient.shared().interfaces() ?? []).compactMap { iface in
            guard let ifaceName = iface.interfaceName else { return nil }
            return (ifaceName, iface.powerOn(), iface.serviceActive())
        }
    }

    // MARK: scan

    public static func scan(
        interfaceName: String? = nil,
        includeSavedNetworks: Bool = true
    ) throws -> ScanOutcome {
        guard let iface = interface(named: interfaceName) else {
            throw ScanFailure.noInterface(interfaceName)
        }
        let name = iface.interfaceName ?? interfaceName ?? "wi-fi"
        guard iface.powerOn() else { throw ScanFailure.poweredOff(name) }

        let started = Date()
        let raw: Set<CWNetwork>
        do {
            raw = try iface.scanForNetworks(withName: nil)
        } catch {
            throw ScanFailure.scanFailed(error.localizedDescription)
        }
        let duration = Date().timeIntervalSince(started)

        let currentSSID = iface.ssid()
        let currentBSSID = iface.bssid()
        let saved = SavedNetworks.preferredSSIDs(interfaceName: name)

        var entries: [NetworkEntry] = []
        var ssidVisible = 0
        var bssidVisible = 0
        var notes: [String] = []

        for network in raw {
            var entry = makeEntry(from: network)
            if entry.ssid != nil { ssidVisible += 1 }
            if entry.bssid != nil { bssidVisible += 1 }
            entry.isSaved = entry.ssid.map { saved.contains($0) } ?? false
            entry.isCurrent = isCurrent(entry, ssid: currentSSID, bssid: currentBSSID)
            entries.append(entry)
        }

        let deduped = dedupe(entries)

        if !deduped.isEmpty, ssidVisible == 0 {
            notes.append(
                "macOS redacted every SSID. Grant Location Services access to the app running "
                    + "wifind (or use the bundled Wifind.app) and scan again."
            )
        } else if !deduped.isEmpty, bssidVisible == 0 {
            notes.append(
                "macOS redacted every BSSID. Rows are keyed by SSID + channel instead; "
                    + "unredacted BSSIDs need a stable code signature."
            )
        }

        var all = deduped
        if includeSavedNetworks, !saved.isEmpty {
            let seen = Set(deduped.compactMap { $0.ssid })
            for ssid in saved.sorted() where !seen.contains(ssid) {
                all.append(
                    NetworkEntry(
                        ssid: ssid,
                        channel: nil,
                        band: .unknown,
                        security: "?",
                        isOpen: false,
                        isCurrent: ssid == currentSSID,
                        isSaved: true
                    )
                )
            }
        }

        return ScanOutcome(
            entries: sortEntries(all, by: .rssi),
            rawCount: raw.count,
            duration: duration,
            ssidVisible: ssidVisible,
            bssidVisible: bssidVisible,
            interfaceName: iface.interfaceName,
            notes: notes
        )
    }

    /// Maps one `CWNetwork` into a row.
    public static func makeEntry(from network: CWNetwork) -> NetworkEntry {
        let channel = network.wlanChannel
        let channelNumber = channel?.channelNumber
        var band: Band = .unknown
        if let channel { band = Band.from(cwBand: channel.channelBand) }
        if band == .unknown, let channelNumber { band = Band.from(channelNumber: channelNumber) }

        let security = securityInfo(for: network)
        let rssi = network.rssiValue != 0 ? network.rssiValue : nil
        let noise = network.noiseMeasurement != 0 ? network.noiseMeasurement : nil

        return NetworkEntry(
            ssid: network.ssid?.isEmpty == false ? network.ssid : nil,
            bssid: network.bssid?.isEmpty == false ? network.bssid?.lowercased() : nil,
            channel: channelNumber,
            band: band,
            widthMHz: channel.flatMap { channelWidthMHz($0.channelWidth) },
            rssi: rssi,
            noise: noise,
            security: security.label,
            isOpen: security.isOpen,
            phyMode: bestPHYMode(of: network),
            isCurrent: false,
            isSaved: false,
            ref: network
        )
    }

    private static func bestPHYMode(of network: CWNetwork) -> String? {
        let modes: [CWPHYMode] = [.mode11ax, .mode11ac, .mode11n, .mode11g, .mode11a, .mode11b]
        for mode in modes where network.supportsPHYMode(mode) {
            return phyModeLabel(mode)
        }
        return nil
    }

    private static func isCurrent(_ entry: NetworkEntry, ssid: String?, bssid: String?) -> Bool {
        if let bssid, let entryBSSID = entry.bssid {
            return bssid.lowercased() == entryBSSID.lowercased()
        }
        if let ssid, let entrySSID = entry.ssid { return ssid == entrySSID }
        return false
    }

    /// One row per access point. When macOS hides BSSIDs, the identity is
    /// SSID + channel, and the strongest report wins.
    public static func dedupe(_ entries: [NetworkEntry]) -> [NetworkEntry] {
        var byKey: [String: NetworkEntry] = [:]
        for entry in entries {
            if let existing = byKey[entry.identityKey] {
                if (entry.rssi ?? Int.min) > (existing.rssi ?? Int.min) {
                    byKey[entry.identityKey] = entry
                }
            } else {
                byKey[entry.identityKey] = entry
            }
        }
        return Array(byKey.values)
    }
}
