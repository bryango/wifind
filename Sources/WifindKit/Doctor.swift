import CoreLocation
import CoreWLAN
import Foundation
import Security

/// Capability report. The user asked for a tool whose scanning is limited by
/// TCC, so `doctor` measures what this process is actually allowed to see
/// instead of assuming.
public struct DoctorReport {
    public var fields: [(String, String)] = []
    public var notes: [String] = []
    public var recommendations: [String] = []
    public var json: [String: Any] = [:]

    public func text() -> String {
        var out = ""
        let labelWidth = fields.map { $0.0.count }.max() ?? 0
        for (label, value) in fields {
            let padded = label + String(repeating: " ", count: max(0, labelWidth - label.count))
            out += "\(padded)  \(value)\n"
        }
        if !notes.isEmpty {
            out += "\nnotes\n"
            for note in notes { out += "  - \(note)\n" }
        }
        if !recommendations.isEmpty {
            out += "\nnext steps\n"
            for item in recommendations { out += "  - \(item)\n" }
        }
        return out
    }

    public func jsonData() -> Data {
        (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }
}

public enum Doctor {
    public static let airportPath =
        "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"

    public static func run(interfaceName: String?, performScan: Bool = true) -> DoctorReport {
        var report = DoctorReport()
        var json: [String: Any] = [:]

        let bundle = Bundle.main
        let bundled = bundle.bundleIdentifier != nil && bundle.bundlePath.hasSuffix(".app")
        let entitlement = entitlementValue("com.apple.developer.networking.wifi-info")
        let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "-"
        let parent = parentProcessName() ?? "-"
        let locationStatus = LocationGate.shared.status
        let interfaceNames = Scanner.interfaceNames()
        let iface = Scanner.interface(named: interfaceName)
        let ifaceName = iface?.interfaceName ?? interfaceName ?? "-"

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let build = sysctlString("kern.osversion") ?? "-"
        let arch = sysctlString("hw.machine") ?? "-"

        report.fields.append(("macOS", "\(version) (\(build)) \(arch)"))
        json["macos"] = version
        json["macos_build"] = build
        json["architecture"] = arch

        report.fields.append(("executable", bundle.executablePath ?? CommandLine.arguments.first ?? "-"))
        report.fields.append(("app bundle", bundled ? "yes (\(bundle.bundlePath))" : "no (bare binary)"))
        json["bundled"] = bundled
        json["bundle_path"] = bundle.bundlePath

        report.fields.append(("terminal", "\(terminal), parent \(parent)"))
        json["terminal"] = terminal
        json["parent_process"] = parent

        report.fields.append(("wi-fi interfaces", interfaceNames.isEmpty ? "none" : interfaceNames.joined(separator: ", ")))
        json["interfaces"] = interfaceNames

        if let iface {
            let power = iface.powerOn() ? "on" : "off"
            let service = iface.serviceActive() ? "active" : "inactive"
            report.fields.append(("selected interface", "\(ifaceName) (power \(power), service \(service))"))
            json["interface_power_on"] = iface.powerOn()
            json["interface_service_active"] = iface.serviceActive()
        } else {
            report.fields.append(("selected interface", "none"))
        }

        let currentSSID = iface?.ssid() ?? iface.flatMap { _ in SavedNetworks.currentSSID(interfaceName: ifaceName) }
        let currentBSSID = iface?.bssid()
        let currentChannel = iface?.wlanChannel()?.channelNumber
        if let currentSSID {
            var text = currentSSID
            if let currentBSSID { text += " (\(currentBSSID)" }
            if let currentChannel { text += currentBSSID == nil ? "(ch \(currentChannel)" : ", ch \(currentChannel)" }
            if currentBSSID != nil || currentChannel != nil { text += ")" }
            report.fields.append(("current network", text))
            json["current_ssid"] = currentSSID
            json["current_bssid"] = currentBSSID ?? ""
            json["current_channel"] = currentChannel ?? 0
        } else {
            report.fields.append(("current network", "not associated"))
        }

        report.fields.append(("location services", LocationGate.label(for: locationStatus)))
        json["location_status"] = LocationGate.label(for: locationStatus)
        json["location_authorized"] = LocationGate.shared.isAuthorized

        report.fields.append((
            "wifi-info entitlement",
            entitlement.map { "present (\($0))" } ?? "absent"
        ))
        json["wifi_info_entitlement"] = entitlement ?? ""

        // The retired airport CLI, probed rather than assumed.
        let airport = runCommand(airportPath, ["-s"], timeout: 6)
        let airportPresent = FileManager.default.isExecutableFile(atPath: airportPath)
        // The stub printed on macOS 14.4+ only emits the deprecation notice
        // (on both stdout and stderr). Real scan rows always carry a BSSID, so
        // look for a MAC address rather than merely for "some output".
        let macPattern = "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}"
        let airportFunctional = airport.map { result in
            !result.timedOut && result.stdout.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).range(of: macPattern, options: .regularExpression) != nil
            }
        } ?? false
        let airportText: String
        if !airportPresent {
            airportText = "not installed"
        } else if airportFunctional {
            airportText = "present and returning scan data"
        } else {
            airportText = "present but non-functional (deprecation stub)"
        }
        report.fields.append(("airport CLI", airportText))
        json["airport_path"] = airportPath
        json["airport_present"] = airportPresent
        json["airport_functional"] = airportFunctional

        let powerState = SavedNetworks.powerState(interfaceName: ifaceName)
        if ifaceName != "-" {
            let preferred = SavedNetworks.preferredSSIDs(interfaceName: ifaceName)
            let powerText = powerState.map { $0 ? "on" : "off" } ?? "unknown"
            report.fields.append(("networksetup", "\(preferred.count) saved networks, power \(powerText)"))
            json["saved_network_count"] = preferred.count
            json["networksetup_power"] = powerText
        }

        if performScan {
            do {
                let outcome = try Scanner.scan(interfaceName: interfaceName, includeSavedNetworks: false)
                let bands = Dictionary(grouping: outcome.entries, by: { $0.band.rawValue }).mapValues { $0.count }
                report.fields.append((
                    "scan",
                    String(
                        format: "%d access points in %.1f s; %d with SSID, %d with BSSID",
                        outcome.rawCount,
                        outcome.duration,
                        outcome.ssidVisible,
                        outcome.bssidVisible
                    )
                ))
                report.fields.append((
                    "bands",
                    Band.ghz2.rawValue + " \(bands[Band.ghz2.rawValue] ?? 0), "
                        + Band.ghz5.rawValue + " \(bands[Band.ghz5.rawValue] ?? 0), "
                        + Band.ghz6.rawValue + " \(bands[Band.ghz6.rawValue] ?? 0)"
                ))
                json["scan_total"] = outcome.rawCount
                json["scan_with_ssid"] = outcome.ssidVisible
                json["scan_with_bssid"] = outcome.bssidVisible
                json["scan_seconds"] = outcome.duration
                json["scan_bands"] = bands
                report.notes.append(contentsOf: outcome.notes)

                if outcome.rawCount > 0, outcome.ssidVisible == 0 {
                    report.recommendations.append(
                        "Enable Location Services for \(bundled ? "wifind" : terminal == "-" ? "your terminal app" : terminal) "
                            + "in System Settings > Privacy & Security > Location Services, then scan again."
                    )
                }
                if outcome.rawCount > 0, outcome.bssidVisible == 0 {
                    report.recommendations.append(
                        "BSSIDs are redacted for this process. macOS returns unredacted BSSIDs only to a "
                            + "stably signed app; without that, wifind keys rows by SSID + channel."
                    )
                }
            } catch {
                report.fields.append(("scan", "failed: \(error)"))
                json["scan_error"] = "\(error)"
                report.recommendations.append("\(error)")
            }
        }

        if !LocationGate.shared.isAuthorized {
            report.recommendations.append(
                LocationAdvice.fix(
                    for: locationStatus,
                    bundled: bundled,
                    parent: terminal == "-" ? parent : terminal
                )
            )
        }
        if !bundled {
            report.recommendations.append(
                "Not running from an app bundle. \"make app\" builds Wifind.app; run "
                    + "./Wifind.app/Contents/MacOS/wifind so macOS attributes Location Services to wifind "
                    + "instead of to \(terminal == "-" ? "your terminal" : terminal)."
            )
        }
        if entitlement == nil, bundled {
            report.notes.append(
                "No com.apple.developer.networking.wifi-info entitlement: macOS 15 redacts Wi-Fi details "
                    + "unless a provisioning profile grants it."
            )
        }

        report.json = json
        return report
    }

    // MARK: helpers

    public static func entitlementValue(_ name: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        guard let value = SecTaskCopyValueForEntitlement(task, name as CFString, nil) else { return nil }
        if let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
        return "\(value)"
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func parentProcessName() -> String? {
        guard let result = runCommand("/bin/ps", ["-o", "comm=", "-p", "\(getppid())"], timeout: 5) else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public struct CommandResult {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @discardableResult
    public static func runCommand(_ path: String, _ args: [String], timeout: TimeInterval) -> CommandResult? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let box = Box<(Data, Data)>((Data(), Data()))
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            box.value = (out, err)
            done.signal()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        let data = box.value
        return CommandResult(
            status: process.isRunning ? -1 : process.terminationStatus,
            stdout: String(data: data.0, encoding: .utf8) ?? "",
            stderr: String(data: data.1, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
