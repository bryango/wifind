import Foundation

/// Thin wrapper around `networksetup`, which still works on macOS 15 even
/// though the `airport` tool no longer does. Used only as a hint source:
/// which SSIDs are saved (so the UI can mark them and try the stored
/// credential) and which SSID is associated right now.
public enum SavedNetworks {
    public static let networksetup = "/usr/sbin/networksetup"

    @discardableResult
    private static func run(_ args: [String]) -> (status: Int32, stdout: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: networksetup)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// SSIDs in the preferred-networks list. `networksetup` indents each entry
    /// with a tab and prints a header line first.
    public static func preferredSSIDs(interfaceName: String) -> Set<String> {
        guard let result = run(["-listpreferredwirelessnetworks", interfaceName]) else { return [] }
        var set = Set<String>()
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t") else { continue }
            let name = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { set.insert(name) }
        }
        return set
    }

    /// The SSID the interface is associated with, per `networksetup`.
    /// Returns nil when the command fails or reports no association.
    public static func currentSSID(interfaceName: String) -> String? {
        guard let result = run(["-getairportnetwork", interfaceName]) else { return nil }
        let text = result.stdout
        guard let range = text.range(of: "Current Wi-Fi Network: ") else { return nil }
        let name = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Wi-Fi power state; nil when unknown.
    public static func powerState(interfaceName: String) -> Bool? {
        guard let result = run(["-getairportpower", interfaceName]) else { return nil }
        if result.stdout.contains(": On") { return true }
        if result.stdout.contains(": Off") { return false }
        return nil
    }

    /// Joins a network, used as the connect fallback when CoreWLAN refuses.
    /// Returns nil when the command could not be started at all.
    public static func setNetwork(interfaceName: String, ssid: String, password: String?) -> (status: Int32, output: String)? {
        var args = ["-setairportnetwork", interfaceName, ssid]
        if let password, !password.isEmpty { args.append(password) }
        guard let result = run(args) else { return nil }
        return (status: result.status, output: result.stdout)
    }
}
