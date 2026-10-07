import CoreWLAN

/// Security classification for one access point.
///
/// CoreWLAN does not expose "the" security mode of a network: it exposes
/// `supportsSecurity(_:)` for each mode. We probe strongest-first so a network
/// advertising WPA2/WPA3 transition shows up as the stronger of the two,
/// which is also how macOS labels it in the Wi-Fi menu.
public struct SecurityInfo {
    public let label: String
    /// Higher is stronger. Used for sorting and for deciding whether a password
    /// prompt is needed.
    public let rank: Int
    public let isOpen: Bool

    public init(label: String, rank: Int, isOpen: Bool) {
        self.label = label
        self.rank = rank
        self.isOpen = isOpen
    }
}

private let probes: [(CWSecurity, SecurityInfo)] = [
    (.wpa3Enterprise, SecurityInfo(label: "WPA3-Ent", rank: 100, isOpen: false)),
    (.wpa3Personal, SecurityInfo(label: "WPA3", rank: 90, isOpen: false)),
    (.wpa3Transition, SecurityInfo(label: "WPA2/WPA3", rank: 80, isOpen: false)),
    // The Swift importer exposes kCWSecurityOWE as uppercase .OWE but
    // kCWSecurityOWETransition as .oweTransition; both spellings are real.
    (.oweTransition, SecurityInfo(label: "OWE", rank: 72, isOpen: true)),
    (.OWE, SecurityInfo(label: "OWE", rank: 70, isOpen: true)),
    (.wpa2Enterprise, SecurityInfo(label: "WPA2-Ent", rank: 65, isOpen: false)),
    (.wpa2Personal, SecurityInfo(label: "WPA2", rank: 60, isOpen: false)),
    (.personal, SecurityInfo(label: "WPA2", rank: 55, isOpen: false)),
    (.wpaEnterprise, SecurityInfo(label: "WPA-Ent", rank: 50, isOpen: false)),
    (.wpaEnterpriseMixed, SecurityInfo(label: "WPA-Ent", rank: 48, isOpen: false)),
    (.wpaPersonal, SecurityInfo(label: "WPA", rank: 40, isOpen: false)),
    (.wpaPersonalMixed, SecurityInfo(label: "WPA/WPA2", rank: 38, isOpen: false)),
    (.enterprise, SecurityInfo(label: "802.1X", rank: 30, isOpen: false)),
    (.dynamicWEP, SecurityInfo(label: "WEP", rank: 20, isOpen: false)),
    (.WEP, SecurityInfo(label: "WEP", rank: 18, isOpen: false)),
    (.none, SecurityInfo(label: "Open", rank: 10, isOpen: true)),
]

public func securityInfo(for network: CWNetwork) -> SecurityInfo {
    for (mode, info) in probes where network.supportsSecurity(mode) {
        return info
    }
    return SecurityInfo(label: "?", rank: 0, isOpen: false)
}
