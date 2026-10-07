import CoreWLAN
import Foundation

/// Radio band of an access point, as shown in the `BAND` column.
public enum Band: String, CaseIterable, Sendable {
    case ghz2 = "2.4G"
    case ghz5 = "5G"
    case ghz6 = "6G"
    case unknown = "?"

    /// Human readable form for the detail line.
    public var longName: String {
        switch self {
        case .ghz2: return "2.4 GHz"
        case .ghz5: return "5 GHz"
        case .ghz6: return "6 GHz"
        case .unknown: return "unknown band"
        }
    }

    /// Map a CoreWLAN band. Returns `.unknown` for `bandUnknown`.
    public static func from(cwBand: CWChannelBand) -> Band {
        switch cwBand {
        case .band2GHz: return .ghz2
        case .band5GHz: return .ghz5
        case .band6GHz: return .ghz6
        default: return .unknown
        }
    }

    /// Numeric fallback used only when CoreWLAN does not report a band.
    ///
    /// 6 GHz channel numbers overlap with the 1-14 range, so a bare channel
    /// number cannot identify 6 GHz; those stay `.unknown` instead of being
    /// guessed.
    public static func from(channelNumber: Int) -> Band {
        switch channelNumber {
        case 1...14: return .ghz2
        case 32...177: return .ghz5
        default: return .unknown
        }
    }
}

/// Maps `CWChannelWidth` to a width in MHz, for the `W` column.
public func channelWidthMHz(_ width: CWChannelWidth) -> Int? {
    switch width {
    case .width20MHz: return 20
    case .width40MHz: return 40
    case .width80MHz: return 80
    case .width160MHz: return 160
    default: return nil
    }
}

/// Maps `CWPHYMode` to a short label.
public func phyModeLabel(_ mode: CWPHYMode) -> String? {
    switch mode {
    case .mode11a: return "802.11a"
    case .mode11b: return "802.11b"
    case .mode11g: return "802.11g"
    case .mode11n: return "802.11n"
    case .mode11ac: return "802.11ac"
    case .mode11ax: return "802.11ax"
    default: return nil
    }
}

/// One row of the list: a single access point (BSSID) or, when macOS redacts
/// the BSSID, the best information available for that SSID + channel.
public struct NetworkEntry {
    public var ssid: String?
    public var bssid: String?
    public var channel: Int?
    public var band: Band
    public var widthMHz: Int?
    public var rssi: Int?
    public var noise: Int?
    public var security: String
    /// True for open / OWE networks: no password prompt is needed.
    public var isOpen: Bool
    public var phyMode: String?
    public var isCurrent: Bool
    public var isSaved: Bool
    /// CoreWLAN handle used by the connect path. Excluded from equality.
    public var ref: CWNetwork?

    public init(
        ssid: String? = nil,
        bssid: String? = nil,
        channel: Int? = nil,
        band: Band = .unknown,
        widthMHz: Int? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        security: String = "?",
        isOpen: Bool = false,
        phyMode: String? = nil,
        isCurrent: Bool = false,
        isSaved: Bool = false,
        ref: CWNetwork? = nil
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.band = band
        self.widthMHz = widthMHz
        self.rssi = rssi
        self.noise = noise
        self.security = security
        self.isOpen = isOpen
        self.phyMode = phyMode
        self.isCurrent = isCurrent
        self.isSaved = isSaved
        self.ref = ref
    }

    /// Identity used for dedupe: BSSID when known, else SSID + channel.
    public var identityKey: String {
        if let bssid, !bssid.isEmpty { return "bssid:\(bssid.lowercased())" }
        let name = ssid ?? "<hidden>"
        return "ssid:\(name)#\(channel.map(String.init) ?? "-")"
    }

    /// What the SSID column shows.
    public var displaySSID: String { ssid ?? "(hidden)" }

    /// What the BSSID column shows.
    public var displayBSSID: String { bssid ?? "--" }

    /// True when the row exists only because the network is saved but was not
    /// seen in the scan.
    public var isOfflineSaved: Bool { isSaved && rssi == nil && !isCurrent }

    /// Sorting / filtering name, stable across redaction.
    public var sortName: String { (ssid ?? bssid ?? "~").lowercased() }
}

extension NetworkEntry: Equatable {
    public static func == (lhs: NetworkEntry, rhs: NetworkEntry) -> Bool {
        lhs.identityKey == rhs.identityKey
            && lhs.rssi == rhs.rssi
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isSaved == rhs.isSaved
    }
}

/// Sort orders reachable with the `s` key.
public enum SortMode: String, CaseIterable, Sendable {
    case rssi = "RSSI"
    case ssid = "SSID"
    case channel = "CH"
    case band = "BAND"
    case security = "SEC"

    public var next: SortMode {
        let all = SortMode.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// Band filter reachable with the `tab` key.
public enum BandFilter: String, CaseIterable, Sendable {
    case all = "all"
    case ghz2 = "2.4G"
    case ghz5 = "5G"
    case ghz6 = "6G"

    public var next: BandFilter {
        let all = BandFilter.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    public func matches(_ entry: NetworkEntry) -> Bool {
        switch self {
        case .all: return true
        case .ghz2: return entry.band == .ghz2
        case .ghz5: return entry.band == .ghz5
        case .ghz6: return entry.band == .ghz6
        }
    }
}

/// Sorts entries for display. Ties fall back to the next key so the order is
/// deterministic between scans.
public func sortEntries(_ entries: [NetworkEntry], by mode: SortMode) -> [NetworkEntry] {
    func rssiKey(_ e: NetworkEntry) -> Int { e.rssi ?? Int.min }
    return entries.sorted { a, b in
        switch mode {
        case .rssi:
            if rssiKey(a) != rssiKey(b) { return rssiKey(a) > rssiKey(b) }
            return a.sortName < b.sortName
        case .ssid:
            if a.sortName != b.sortName { return a.sortName < b.sortName }
            return rssiKey(a) > rssiKey(b)
        case .channel:
            let ca = a.channel ?? Int.max, cb = b.channel ?? Int.max
            if ca != cb { return ca < cb }
            return rssiKey(a) > rssiKey(b)
        case .band:
            let ba = bandRank(a.band), bb = bandRank(b.band)
            if ba != bb { return ba < bb }
            return rssiKey(a) > rssiKey(b)
        case .security:
            if a.security != b.security { return a.security < b.security }
            return rssiKey(a) > rssiKey(b)
        }
    }
}

private func bandRank(_ band: Band) -> Int {
    switch band {
    case .ghz2: return 0
    case .ghz5: return 1
    case .ghz6: return 2
    case .unknown: return 3
    }
}

/// Case-insensitive substring filter over SSID and BSSID.
public func filterEntries(_ entries: [NetworkEntry], query: String) -> [NetworkEntry] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return entries }
    return entries.filter { entry in
        if let ssid = entry.ssid, ssid.lowercased().contains(needle) { return true }
        if let bssid = entry.bssid, bssid.lowercased().contains(needle) { return true }
        return false
    }
}

/// Signal bars used in the RSSI column.
public func signalBars(_ rssi: Int?) -> String {
    guard let rssi else { return "    " }
    let full: Int
    switch rssi {
    case (-55)...: full = 4
    case (-65)...: full = 3
    case (-75)...: full = 2
    case (-85)...: full = 1
    default: full = 0
    }
    return String(repeating: "\u{2582}", count: full) + String(repeating: "_", count: 4 - full)
}
