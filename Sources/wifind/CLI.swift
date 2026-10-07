import CoreLocation
import Foundation
import WifindKit

enum CLI {
    static let version = "0.1.0"

    static func usage() -> String {
        """
        wifind - scan nearby Wi-Fi and connect to an access point from the terminal

        usage
          wifind                        interactive list (default)
          wifind scan [options]         print the scan as a table
          wifind connect <ssid> [opts]  join a network
          wifind doctor [options]       report what macOS lets this process see
          wifind helper [options]       internal: serve one request from the app bundle

        options
          --iface <name>       Wi-Fi interface (default: system default, usually en0)
          --json               machine readable output (scan, doctor)
          --band <all|2.4|5|6> restrict to one band
          --sort <mode>        rssi (default), ssid, ch, band, sec
          --no-saved           do not add saved-but-out-of-range networks
          --bssid <mac>        connect: pick one access point of a multi-BSSID network
          --channel <n>        connect: pick one channel
          --password-stdin     connect: read the password from stdin
          --request-location   scan/doctor: ask for Location Services first
          --out <path>         scan/doctor: write the output to a file
          --no-helper          do not fall back to scanning inside Wifind.app
          --no-scan            doctor: skip the scan probe
          -h, --help           this text
          --version            print the version

        The interactive UI: up/down or j/k move, enter connects, r rescans,
        / filters, tab cycles the band filter, s cycles the sort, ? shows help,
        q quits.
        """
    }

    // MARK: argument parsing

    struct Args {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        func value(_ name: String) -> String? { values[name] }
        func flag(_ name: String) -> Bool { flags.contains(name) }
    }

    private static let valueFlags: Set<String> = [
        "--iface", "--band", "--sort", "--bssid", "--channel", "--out",
        "--request", "--response",
    ]

    static func parse(_ arguments: [String]) -> Args {
        var args = Args()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    let name = String(argument[argument.startIndex..<equals])
                    args.values[name] = String(argument[argument.index(after: equals)...])
                } else if valueFlags.contains(argument), index + 1 < arguments.count {
                    args.values[argument] = arguments[index + 1]
                    index += 1
                } else {
                    args.flags.insert(argument)
                }
            } else if argument == "-h" {
                args.flags.insert("--help")
            } else {
                args.positional.append(argument)
            }
            index += 1
        }
        return args
    }

    // MARK: entry point

    static func run(arguments: [String]) -> Int32 {
        var arguments = arguments
        var command = "tui"
        if let first = arguments.first, !first.hasPrefix("-") {
            command = first
            arguments.removeFirst()
        }
        let args = parse(arguments)

        if args.flag("--help") || command == "help" {
            print(usage())
            return 0
        }
        if args.flag("--version") || command == "version" {
            print("wifind \(version)")
            return 0
        }

        switch command {
        case "tui":
            return runTUI(
                interfaceName: args.value("--iface"),
                allowsHelper: !args.flag("--no-helper")
            )
        case "scan": return scanCommand(args)
        case "connect": return connectCommand(args)
        case "doctor": return doctorCommand(args)
        case "helper": return helperCommand(args)
        default:
            FileHandle.standardError.write(Data("wifind: unknown command \"\(command)\"\n\n".utf8))
            FileHandle.standardError.write(Data(usage().utf8))
            return 2
        }
    }

    // MARK: scan

    static func scanEntries(_ args: Args) throws -> ScanOutcome {
        var outcome = try Preferred.scan(
            interfaceName: args.value("--iface"),
            includeSavedNetworks: !args.flag("--no-saved"),
            route: args.flag("--no-helper") ? .localOnly : .automatic,
            progress: { message in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
        )
        if let band = bandArgument(args.value("--band")) {
            outcome.entries = outcome.entries.filter { band.matches($0) }
        }
        outcome.entries = sortEntries(outcome.entries, by: sortArgument(args.value("--sort")))
        return outcome
    }

    static func scanCommand(_ args: Args) -> Int32 {
        requestLocationIfAsked(args)
        do {
            let outcome = try scanEntries(args)
            let text = args.flag("--json") ? jsonString(scanJSON(outcome)) : scanTable(outcome)
            emit(text, to: args.value("--out"))
            if !args.flag("--json") {
                for note in outcome.notes {
                    FileHandle.standardError.write(Data("note: \(note)\n".utf8))
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("wifind: \(error)\n".utf8))
            return 1
        }
    }

    static func scanJSON(_ outcome: ScanOutcome) -> [String: Any] {
        var json: [String: Any] = [
            "interface": outcome.interfaceName ?? "",
            "count": outcome.entries.count,
            "raw_count": outcome.rawCount,
            "ssid_visible": outcome.ssidVisible,
            "bssid_visible": outcome.bssidVisible,
                "duration_seconds": outcome.duration,
                "notes": outcome.notes,
                "route": outcome.route.rawValue,
                "helper_bundle": outcome.helperBundle ?? "",
        ]
        json["access_points"] = outcome.entries.map { entry -> [String: Any] in
            var item: [String: Any] = [
                "band": entry.band.rawValue,
                "security": entry.security,
                "current": entry.isCurrent,
                "saved": entry.isSaved,
                "out_of_range": entry.isOfflineSaved,
                "open": entry.isOpen,
            ]
            item["ssid"] = entry.ssid ?? NSNull()
            item["bssid"] = entry.bssid ?? NSNull()
            item["channel"] = entry.channel ?? NSNull()
            item["width_mhz"] = entry.widthMHz ?? NSNull()
            item["rssi"] = entry.rssi ?? NSNull()
            item["noise"] = entry.noise ?? NSNull()
            item["phy"] = entry.phyMode ?? NSNull()
            return item
        }
        return json
    }

    static func scanTable(_ outcome: ScanOutcome) -> String {
        let colour = isatty(STDOUT_FILENO) == 1
        let entries = outcome.entries
        let ssidWidth = min(34, max(14, entries.map { Display.width($0.displaySSID) }.max() ?? 14))
        let securityWidth = max(3, entries.map { $0.security.count }.max() ?? 3)
        var lines: [String] = []

        func row(_ cells: [(String, Int, Bool)]) -> String {
            var text = ""
            for (value, width, right) in cells {
                text += Display.pad(value, width: width, alignRight: right) + " "
            }
            return text
        }

        lines.append(row([
            ("BAND", 4, false),
            ("SSID", ssidWidth, false),
            ("BSSID", 17, false),
            ("CH", 4, true),
            ("W", 4, true),
            ("RSSI", 5, true),
            ("SEC", securityWidth, false),
            ("F", 3, false),
        ]))

        for entry in entries {
            var flags = ""
            if entry.isCurrent { flags += "*" }
            if entry.isSaved { flags += "S" }
            if entry.isOfflineSaved { flags += "-" }
            let cells: [(String, Int, Bool)] = [
                (entry.band.rawValue, 4, false),
                (entry.displaySSID, ssidWidth, false),
                (entry.displayBSSID, 17, false),
                (entry.channel.map(String.init) ?? "-", 4, true),
                (entry.widthMHz.map(String.init) ?? "-", 4, true),
                (entry.rssi.map(String.init) ?? "-", 5, true),
                (entry.security, securityWidth, false),
                (flags, 3, false),
            ]
            var text = row(cells)
            if colour {
                let bandColour: String
                switch entry.band {
                case .ghz2: bandColour = "\u{1B}[33m"
                case .ghz5: bandColour = "\u{1B}[36m"
                case .ghz6: bandColour = "\u{1B}[35m"
                case .unknown: bandColour = "\u{1B}[90m"
                }
                text = bandColour + text + "\u{1B}[0m"
            }
            lines.append(text)
        }

        let seconds = String(format: "%.1f", outcome.duration)
        lines.append("")
        lines.append(
            "\(entries.count) access points from \(outcome.rawCount) reports in \(seconds) s"
                + " (\(outcome.ssidVisible) with SSID, \(outcome.bssidVisible) with BSSID)"
        )
        if entries.contains(where: { $0.isOfflineSaved }) {
            lines.append("rows marked S- are saved networks that are not in range right now")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: connect

    static func connectCommand(_ args: Args) -> Int32 {
        guard let ssid = args.positional.first else {
            FileHandle.standardError.write(Data("wifind: connect needs an SSID\n".utf8))
            return 2
        }
        let wantedBSSID = args.value("--bssid")?.lowercased()
        let wantedChannel = args.value("--channel").flatMap(Int.init)

        let scanned: [NetworkEntry]
        do {
            scanned = try Preferred.scan(
                interfaceName: args.value("--iface"),
                includeSavedNetworks: true,
                route: args.flag("--no-helper") ? .localOnly : .automatic,
                progress: { message in
                    FileHandle.standardError.write(Data("\(message)\n".utf8))
                }
            ).entries
        } catch {
            FileHandle.standardError.write(Data("wifind: \(error)\n".utf8))
            return 1
        }

        guard let target = scanned.first(where: { entry in
            guard entry.ssid == ssid else { return false }
            if let wantedBSSID, entry.bssid?.lowercased() != wantedBSSID { return false }
            if let wantedChannel, entry.channel != wantedChannel { return false }
            return true
        }) else {
            FileHandle.standardError.write(Data("wifind: \"\(ssid)\" is not visible right now\n".utf8))
            return 1
        }
        var password: String?
        if args.flag("--password-stdin") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            password = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
        } else if !target.isOpen {
            if target.isSaved, let found = savedPassword(for: ssid) {
                password = found
            } else {
                password = promptPassword("Password for \(ssid): ")
            }
        }

        let outcome = Preferred.connect(
            entry: target,
            password: password,
            interfaceName: args.value("--iface"),
            route: args.flag("--no-helper") ? .localOnly : .automatic,
            timeout: 20
        ) { message in
            FileHandle.standardError.write(Data("\(message)\n".utf8))
        }

        switch outcome {
        case .connected(let via):
            print("connected to \(ssid) via \(via)")
            return 0
        case .failed(let message):
            FileHandle.standardError.write(Data("wifind: \(message)\n".utf8))
            return 1
        }
    }

    static func savedPassword(for ssid: String) -> String? {
        if case .found(let password) = Keychain.password(for: ssid) { return password }
        return nil
    }

    /// Echo-free prompt. Returns nil when there is no terminal to read from.
    static func promptPassword(_ prompt: String) -> String? {
        guard let tty = fopen("/dev/tty", "r+") else { return nil }
        defer { fclose(tty) }
        fputs(prompt, tty)
        fflush(tty)
        let fd = fileno(tty)
        var original = termios()
        tcgetattr(fd, &original)
        var hidden = original
        hidden.c_lflag &= ~UInt(ECHO)
        tcsetattr(fd, TCSANOW, &hidden)
        var bytes: [CChar] = []
        while true {
            let character = fgetc(tty)
            if character == EOF || character == 10 { break }
            if character == 13 { continue }
            bytes.append(CChar(character))
        }
        tcsetattr(fd, TCSANOW, &original)
        fputs("\n", tty)
        fflush(tty)
        return String(cString: bytes + [0])
    }

    // MARK: doctor

    /// Internal entry point used by the app bundle it launches itself. Reads a
    /// request file, writes an answer file, and stays off stdout because a
    /// LaunchServices launch has no terminal.
    static func helperCommand(_ args: Args) -> Int32 {
        guard let requestPath = args.value("--request"),
              let responsePath = args.value("--response")
        else {
            FileHandle.standardError.write(Data("wifind: helper needs --request and --response\n".utf8))
            return 2
        }
        return Helper.serve(requestPath: requestPath, responsePath: responsePath)
    }

    static func doctorCommand(_ args: Args) -> Int32 {
        requestLocationIfAsked(args)
        let report = Doctor.run(
            interfaceName: args.value("--iface"),
            performScan: !args.flag("--no-scan")
        )
        emit(args.flag("--json") ? jsonString(report.json) : report.text(), to: args.value("--out"))
        return 0
    }

    // MARK: helpers

    /// Writes to stdout, or to a file when asked. The file route exists because
    /// a bundle launched through LaunchServices (open -W) has no terminal, and
    /// that launch mode is one of the things worth being able to test.
    static func emit(_ text: String, to path: String?) {
        guard let path else {
            print(text)
            return
        }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("wifind: could not write \(path): \(error)\n".utf8))
        }
    }

    /// Scanning only returns SSIDs to a process that may use Location
    /// Services, so the prompt is opt-in for the non-interactive commands
    /// (the TUI always asks when the status is still undetermined).
    static func requestLocationIfAsked(_ args: Args) {
        guard args.flag("--request-location") else { return }
        let status = LocationGate.shared.requestIfNeeded(timeout: 30)
        FileHandle.standardError.write(
            Data("location services: \(LocationGate.label(for: status))\n".utf8)
        )
    }

    static func bandArgument(_ text: String?) -> BandFilter? {
        guard let text = text?.lowercased() else { return nil }
        switch text {
        case "all", "": return nil
        case "2.4", "2.4g", "2g", "2": return .ghz2
        case "5", "5g": return .ghz5
        case "6", "6g": return .ghz6
        default: return nil
        }
    }

    static func sortArgument(_ text: String?) -> SortMode {
        switch text?.lowercased() {
        case "ssid": return .ssid
        case "ch", "channel": return .channel
        case "band": return .band
        case "sec", "security": return .security
        default: return .rssi
        }
    }

    static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
