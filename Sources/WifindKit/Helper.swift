import Foundation

/// Request served by the privileged helper.
public struct HelperRequest: Codable {
    public enum Action: String, Codable {
        case scan
        case connect
    }

    public var action: Action
    public var iface: String?
    public var ssid: String?
    public var bssid: String?
    public var channel: Int?
    /// Sent in a 0600 file, never on the command line.
    public var password: String?
    public var timeout: Double?
    /// Keep saved-but-out-of-range rows in the scan result.
    public var includeSaved: Bool?

    public init(
        action: Action,
        iface: String? = nil,
        ssid: String? = nil,
        bssid: String? = nil,
        channel: Int? = nil,
        password: String? = nil,
        timeout: Double? = nil,
        includeSaved: Bool? = nil
    ) {
        self.action = action
        self.iface = iface
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.password = password
        self.timeout = timeout
        self.includeSaved = includeSaved
    }
}

/// What the helper reports back.
public struct HelperResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var via: String?
    public var interface: String?
    public var rawCount: Int?
    public var ssidVisible: Int?
    public var bssidVisible: Int?
    public var duration: Double?
    public var notes: [String]?
    public var accessPoints: [HelperAccessPoint]?

    public init(
        ok: Bool,
        error: String? = nil,
        via: String? = nil,
        interface: String? = nil,
        rawCount: Int? = nil,
        ssidVisible: Int? = nil,
        bssidVisible: Int? = nil,
        duration: Double? = nil,
        notes: [String]? = nil,
        accessPoints: [HelperAccessPoint]? = nil
    ) {
        self.ok = ok
        self.error = error
        self.via = via
        self.interface = interface
        self.rawCount = rawCount
        self.ssidVisible = ssidVisible
        self.bssidVisible = bssidVisible
        self.duration = duration
        self.notes = notes
        self.accessPoints = accessPoints
    }
}

/// Wire form of one row. Kept separate from NetworkEntry because the helper
/// cannot hand over a CoreWLAN object, only values.
public struct HelperAccessPoint: Codable {
    public var ssid: String?
    public var bssid: String?
    public var channel: Int?
    public var widthMHz: Int?
    public var rssi: Int?
    public var noise: Int?
    public var band: String?
    public var security: String?
    public var phy: String?
    public var current: Bool?
    public var saved: Bool?
    public var outOfRange: Bool?
    public var open: Bool?

    public init(
        ssid: String? = nil,
        bssid: String? = nil,
        channel: Int? = nil,
        widthMHz: Int? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        band: String? = nil,
        security: String? = nil,
        phy: String? = nil,
        current: Bool? = nil,
        saved: Bool? = nil,
        outOfRange: Bool? = nil,
        open: Bool? = nil
    ) {
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.widthMHz = widthMHz
        self.rssi = rssi
        self.noise = noise
        self.band = band
        self.security = security
        self.phy = phy
        self.current = current
        self.saved = saved
        self.outOfRange = outOfRange
        self.open = open
    }

    public init(entry: NetworkEntry) {
        self.init(
            ssid: entry.ssid,
            bssid: entry.bssid,
            channel: entry.channel,
            widthMHz: entry.widthMHz,
            rssi: entry.rssi,
            noise: entry.noise,
            band: entry.band.rawValue,
            security: entry.security,
            phy: entry.phyMode,
            current: entry.isCurrent,
            saved: entry.isSaved,
            outOfRange: entry.isOfflineSaved,
            open: entry.isOpen
        )
    }

    public func entry() -> NetworkEntry {
        NetworkEntry(
            ssid: ssid,
            bssid: bssid,
            channel: channel,
            band: band.flatMap(Band.init(rawValue:)) ?? .unknown,
            widthMHz: widthMHz,
            rssi: rssi,
            noise: noise,
            security: security ?? "?",
            isOpen: open ?? false,
            phyMode: phy,
            isCurrent: current ?? false,
            isSaved: saved ?? false,
            ref: nil
        )
    }
}

/// Launches the app bundle through LaunchServices so the scan runs with the
/// Wi-Fi data macOS only hands to a bundle launched by launchd.
///
/// Measured on macOS 15.7.5 with the same signed binary and the same Location
/// Services grant: executed from a shell it sees 0 of 15 SSIDs and 0 of 15
/// BSSIDs; launched with 'open -W' it sees all 15 of each. The signature and
/// the entitlement are not what unlock it, the launch context is.
public enum Helper {
    public static let environmentKey = "WIFIND_APP"

    /// Path of the app bundle to launch, or nil when there is none to use.
    public static func locateAppBundle() -> String? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            candidates.append(override)
        }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") { candidates.append(bundlePath) }
        if let executable = Bundle.main.executablePath {
            var directory = (executable as NSString).deletingLastPathComponent
            for _ in 0..<3 {
                candidates.append((directory as NSString).appendingPathComponent("Wifind.app"))
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        candidates.append(("/Applications" as NSString).appendingPathComponent("Wifind.app"))

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else { continue }
            let executable = (candidate as NSString).appendingPathComponent("Contents/MacOS/wifind")
            if fileManager.isExecutableFile(atPath: executable) {
                return (candidate as NSString).standardizingPath
            }
        }
        return nil
    }

    /// True when this process is already the launchd-launched helper, in which
    /// case it must never delegate again.
    public static var runningAsHelper: Bool {
        getppid() == 1 || ProcessInfo.processInfo.arguments.contains("helper")
    }

    public enum HelperError: Error, CustomStringConvertible {
        case noBundle
        case launchFailed(String)
        case timedOut
        case badResponse(String)

        public var description: String {
            switch self {
            case .noBundle:
                return "no Wifind.app bundle found; run 'make app' or set \(environmentKey)"
            case .launchFailed(let message):
                return "could not launch the helper: \(message)"
            case .timedOut:
                return "the helper did not answer in time"
            case .badResponse(let message):
                return "the helper answered with something unusable: \(message)"
            }
        }
    }

    /// Runs one request in the app bundle and returns its answer.
    public static func call(
        _ request: HelperRequest,
        bundle: String? = nil,
        timeout: TimeInterval = 60
    ) throws -> HelperResponse {
        guard let bundle = bundle ?? locateAppBundle() else { throw HelperError.noBundle }

        let fileManager = FileManager.default
        let scratch = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wifind-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try? fileManager.createDirectory(
            atPath: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(atPath: scratch) }

        let requestPath = (scratch as NSString).appendingPathComponent("request.json")
        let responsePath = (scratch as NSString).appendingPathComponent("response.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(request)
        guard fileManager.createFile(
            atPath: requestPath,
            contents: payload,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw HelperError.launchFailed("could not write \(requestPath)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-n", "-W", bundle,
            "--args", "helper",
            "--request", requestPath,
            "--response", responsePath,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw HelperError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            process.terminate()
            throw HelperError.timedOut
        }
        guard process.terminationStatus == 0 else {
            throw HelperError.launchFailed("open exited \(process.terminationStatus)")
        }
        guard let data = fileManager.contents(atPath: responsePath) else {
            throw HelperError.badResponse("no response file")
        }
        do {
            return try JSONDecoder().decode(HelperResponse.self, from: data)
        } catch {
            throw HelperError.badResponse(error.localizedDescription)
        }
    }

    /// Runs the helper side: reads a request file, performs it, writes the
    /// answer. Called inside the bundle; never delegates further.
    public static func serve(requestPath: String, responsePath: String) -> Int32 {
        func write(_ response: HelperResponse) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(response) else { return }
            try? data.write(to: URL(fileURLWithPath: responsePath), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: responsePath
            )
        }

        guard let data = FileManager.default.contents(atPath: requestPath),
              let request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        else {
            write(HelperResponse(ok: false, error: "unreadable request"))
            return 2
        }
        try? FileManager.default.removeItem(atPath: requestPath)

        switch request.action {
        case .scan:
            do {
                let outcome = try Scanner.scan(
                    interfaceName: request.iface,
                    includeSavedNetworks: request.includeSaved ?? true
                )
                write(HelperResponse(
                    ok: true,
                    interface: outcome.interfaceName,
                    rawCount: outcome.rawCount,
                    ssidVisible: outcome.ssidVisible,
                    bssidVisible: outcome.bssidVisible,
                    duration: outcome.duration,
                    notes: outcome.notes,
                    accessPoints: outcome.entries.map(HelperAccessPoint.init(entry:))
                ))
                return 0
            } catch {
                write(HelperResponse(ok: false, error: "\(error)"))
                return 1
            }
        case .connect:
            let entry = NetworkEntry(
                ssid: request.ssid,
                bssid: request.bssid,
                channel: request.channel,
                ref: nil
            )
            let outcome = Associator.connect(
                entry: entry,
                password: request.password,
                interfaceName: request.iface,
                timeout: request.timeout ?? 20
            ) { _ in }
            switch outcome {
            case .connected(let via):
                write(HelperResponse(ok: true, via: via))
                return 0
            case .failed(let message):
                write(HelperResponse(ok: false, error: message))
                return 1
            }
        }
    }
}
