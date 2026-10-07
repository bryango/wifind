import Foundation

/// Entry points that pick the right execution context automatically.
///
/// Scanning inside this process returns redacted data whenever macOS has not
/// granted the Wi-Fi privilege to its launch context, which happens for
/// anything started from a shell. The privileged context is the app bundle
/// launched by launchd, so these helpers retry there instead of silently
/// showing a list of anonymous access points.
public enum Preferred {
    /// How a caller wants the privilege problem handled.
    public enum Route {
        /// Use the helper when the local scan comes back redacted.
        case automatic
        /// Stay in this process, redaction and all.
        case localOnly

        var allowsHelper: Bool { self == .automatic }
    }

    /// Scans, falling back to the app-bundle helper when macOS redacts the
    /// local result.
    ///
    /// - Parameter progress: called with human readable state changes, for the
    ///   TUI status line.
    public static func scan(
        interfaceName: String?,
        includeSavedNetworks: Bool = true,
        route: Route = .automatic,
        bundle: String? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> ScanOutcome {
        var outcome = try Scanner.scan(
            interfaceName: interfaceName,
            includeSavedNetworks: includeSavedNetworks
        )
        guard route.allowsHelper,
              outcome.rawCount > 0,
              outcome.ssidVisible == 0,
              !Helper.runningAsHelper
        else { return outcome }

        progress?("macOS hid the names here; scanning through Wifind.app...")
        do {
            let response = try Helper.call(
                HelperRequest(
                    action: .scan,
                    iface: interfaceName,
                    includeSaved: includeSavedNetworks
                ),
                bundle: bundle
            )
            guard let rows = response.accessPoints, !rows.isEmpty else {
                throw Helper.HelperError.badResponse(response.error ?? "no access points")
            }
            var entries = rows.map { $0.entry() }
            entries = sortEntries(Scanner.dedupe(entries), by: .rssi)
            progress?("Scanned \(entries.count) access points through Wifind.app")
            return ScanOutcome(
                entries: entries,
                rawCount: response.rawCount ?? entries.count,
                duration: response.duration ?? outcome.duration,
                ssidVisible: response.ssidVisible ?? entries.filter { $0.ssid != nil }.count,
                bssidVisible: response.bssidVisible ?? entries.filter { $0.bssid != nil }.count,
                interfaceName: response.interface ?? outcome.interfaceName,
                notes: response.notes ?? [],
                route: .helper,
                helperBundle: bundle ?? Helper.locateAppBundle()
            )
        } catch {
            // Keep the redacted list, but say why it is redacted.
            outcome.notes.append(
                "The app-bundle scan could not run (\(error))."
            )
            return outcome
        }
    }

    /// Joins a network, using the privileged context when the row came from it.
    public static func connect(
        entry: NetworkEntry,
        password: String?,
        interfaceName: String?,
        route: Route = .automatic,
        bundle: String? = nil,
        timeout: TimeInterval = 20,
        progress: @escaping (String) -> Void
    ) -> AssociateOutcome {
        // A row with a CoreWLAN handle can be joined right here. Rows that
        // crossed the process boundary have none, and a local rescan cannot
        // find them because this process cannot read network identities.
        let needsHelper = entry.ref == nil && route.allowsHelper && !Helper.runningAsHelper
        guard needsHelper else {
            return Associator.connect(
                entry: entry,
                password: password,
                interfaceName: interfaceName,
                timeout: timeout,
                progress: progress
            )
        }
        progress("Asking Wifind.app to join \(entry.displaySSID)...")
        do {
            let response = try Helper.call(
                HelperRequest(
                    action: .connect,
                    iface: interfaceName,
                    ssid: entry.ssid,
                    bssid: entry.bssid,
                    channel: entry.channel,
                    password: password,
                    timeout: timeout
                ),
                bundle: bundle,
                timeout: timeout + 45
            )
            if response.ok {
                return .connected(via: response.via ?? "Wifind.app")
            }
            return .failed(response.error ?? "the helper could not join \(entry.displaySSID)")
        } catch {
            // Last resort: networksetup talks to the system daemon and does not
            // need the Wi-Fi privilege.
            guard let ssid = entry.ssid else {
                return .failed("\(error)")
            }
            progress("Falling back to networksetup...")
            if let result = SavedNetworks.setNetwork(
                interfaceName: interfaceName ?? "en0",
                ssid: ssid,
                password: password
            ), result.status == 0 {
                return .connected(via: "networksetup")
            }
            return .failed("\(error)")
        }
    }
}
