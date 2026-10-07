import Foundation
import CoreLocation
import WifindKit

// MARK: - styling

private enum Style {
    static let reset = "\u{1B}[0m"
    static let dim = "\u{1B}[2m"
    static let bold = "\u{1B}[1m"
    static let selectedRow = "\u{1B}[48;5;236m"
    static let cursor = "\u{1B}[1;32m"
    static let current = "\u{1B}[1;32m"
    static let warn = "\u{1B}[33m"
    static let error = "\u{1B}[1;31m"
    static let ok = "\u{1B}[32m"
    static let grey = "\u{1B}[90m"

    static func band(_ band: Band) -> String {
        switch band {
        case .ghz2: return "\u{1B}[33m"
        case .ghz5: return "\u{1B}[36m"
        case .ghz6: return "\u{1B}[35m"
        case .unknown: return "\u{1B}[90m"
        }
    }
}

private enum Mode {
    case list
    case filter
    case password
    case help
}

// MARK: - state

/// Everything the renderer reads. Copied under a lock so the UI thread never
/// races the background scan / connect work.
private struct UIState {
    var entries: [NetworkEntry] = []
    var scanning = false
    var lastScanAt: Date?
    var lastDuration: TimeInterval = 0
    var rawCount = 0
    var ssidVisible = 0
    var bssidVisible = 0
    var notes: [String] = []
    var status = "Starting up..."
    var statusIsError = false
    var selectedKey: String?
    var selectedIndex = 0
    var sort: SortMode = .rssi
    var bandFilter: BandFilter = .all
    var query = ""
    var mode: Mode = .list
    var filterDraft = ""
    var passwordDraft = ""
    var passwordHint = ""
    var passwordTarget: NetworkEntry?
    var connectingKey: String?
    var ifaceName: String = "en0"
    var locationStatus: CLAuthorizationStatus = .notDetermined
    var route: ScanRoute = .local
    var quit = false
    var needsRedraw = true
    var spinner = 0
}

private final class AppState {
    private let lock = NSLock()
    private var state = UIState()

    var snapshot: UIState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func update(_ body: (inout UIState) -> Void) {
        lock.lock()
        body(&state)
        lock.unlock()
    }
}

// MARK: - background work

private final class Engine {
    private let state: AppState
    private let queue = DispatchQueue(label: "wifind.work", qos: .userInitiated)
    /// Permission waits must not sit in front of scans, and must never block
    /// the render loop.
    private let permissionQueue = DispatchQueue(label: "wifind.permission", qos: .utility)
    private let allowsHelper: Bool

    init(state: AppState, allowsHelper: Bool) {
        self.state = state
        self.allowsHelper = allowsHelper
    }

    func scan() {
        let busy = state.snapshot.scanning
        guard !busy else { return }
        let iface = state.snapshot.ifaceName
        state.update {
            $0.scanning = true
            $0.status = "Scanning..."
            $0.statusIsError = false
            $0.needsRedraw = true
        }
        let route: Preferred.Route = self.allowsHelper ? .automatic : .localOnly
        queue.async { [state] in
            do {
                let outcome = try Preferred.scan(
                    interfaceName: iface,
                    route: route,
                    progress: { message in
                        state.update {
                            $0.status = message
                            $0.needsRedraw = true
                        }
                    }
                )
                state.update { s in
                    s.entries = outcome.entries
                    s.scanning = false
                    s.lastScanAt = Date()
                    s.lastDuration = outcome.duration
                    s.rawCount = outcome.rawCount
                    s.ssidVisible = outcome.ssidVisible
                    s.bssidVisible = outcome.bssidVisible
                    s.notes = outcome.notes
                    s.route = outcome.route
                    var status = String(
                        format: "Scanned %d access points in %.1f s",
                        outcome.rawCount,
                        outcome.duration
                    )
                    if outcome.route == .helper { status += " via Wifind.app" }
                    s.status = status
                    s.statusIsError = false
                    s.needsRedraw = true
                }
            } catch {
                state.update { s in
                    s.scanning = false
                    s.status = "\(error)"
                    s.statusIsError = true
                    s.needsRedraw = true
                }
            }
        }
    }

    /// Asks for Location Services without freezing the UI.
    ///
    /// The first version called the blocking request before entering the loop,
    /// which left the screen showing a single frozen line for up to thirty
    /// seconds whenever the prompt could not be answered.
    func requestLocationPermission() {
        permissionQueue.async { [state] in
            let status = LocationGate.shared.requestIfNeeded(timeout: 30)
            state.update {
                $0.locationStatus = status
                $0.status = status == .authorizedAlways
                    ? "Location Services granted; scanning"
                    : "Location Services \(LocationGate.label(for: status))"
                $0.statusIsError = status != .authorizedAlways
                $0.needsRedraw = true
            }
        }
    }

    func connect(entry: NetworkEntry, password: String?) {
        let iface = state.snapshot.ifaceName
        let route: Preferred.Route = self.allowsHelper ? .automatic : .localOnly
        state.update {
            $0.connectingKey = entry.identityKey
            $0.status = "Connecting to \(entry.displaySSID)..."
            $0.statusIsError = false
            $0.needsRedraw = true
        }
        queue.async { [state] in
            let outcome = Preferred.connect(
                entry: entry,
                password: password,
                interfaceName: iface,
                route: route,
                timeout: 20
            ) { message in
                state.update {
                    $0.status = message
                    $0.needsRedraw = true
                }
            }
            var connected = false
            state.update { s in
                s.connectingKey = nil
                switch outcome {
                case .connected(let via):
                    s.status = "Connected to \(entry.displaySSID) via \(via)"
                    s.statusIsError = false
                    connected = true
                case .failed(let message):
                    s.status = message
                    s.statusIsError = true
                }
                s.needsRedraw = true
            }
            if connected { self.scan() }
        }
    }
}

// MARK: - app

private final class TUIApp {
    private let term: Terminal
    private let state = AppState()
    private let engine: Engine
    private let started = Date()

    init(term: Terminal, interfaceName: String?, allowsHelper: Bool) {
        self.term = term
        self.engine = Engine(state: state, allowsHelper: allowsHelper)
        let resolved = interfaceName
            ?? Scanner.interface(named: nil)?.interfaceName
            ?? Scanner.interfaceNames().first
            ?? "en0"
        state.update { $0.ifaceName = resolved }
    }

    // MARK: run loop

    func run() -> Int32 {
        Terminal.installSignalHandlers()
        term.enterRawMode()
        defer { term.restore() }

        state.update { $0.locationStatus = LocationGate.shared.status }
        render()
        if LocationGate.shared.status == .notDetermined {
            state.update {
                $0.status = "Requesting Location Services permission - answer the dialog, keys still work"
                $0.needsRedraw = true
            }
            render()
            engine.requestLocationPermission()
        }

        engine.scan()
        var rescannedAfterGrant = LocationGate.shared.isAuthorized

        while true {
            if Terminal.quitPendingFlag { break }
            if Terminal.resizePendingFlag {
                Terminal.clearResizeFlag()
                term.updateSize()
                state.update { $0.needsRedraw = true }
            }
            if let key = term.readKey(timeout: 0.1) {
                handle(key)
            }
            // The permission can resolve at any moment, and a granted
            // permission means the previous scan was redacted, so scan again.
            let status = LocationGate.shared.status
            if status != state.snapshot.locationStatus {
                let wasGranted = state.snapshot.locationStatus == .authorizedAlways
                state.update {
                    $0.locationStatus = status
                    $0.needsRedraw = true
                }
                if status == .authorizedAlways, !wasGranted, !rescannedAfterGrant {
                    rescannedAfterGrant = true
                    engine.scan()
                }
            }
            let snap = state.snapshot
            if snap.quit { break }
            if snap.scanning || snap.connectingKey != nil {
                state.update {
                    $0.spinner = ($0.spinner + 1) % 10
                    $0.needsRedraw = true
                }
            }
            if state.snapshot.needsRedraw {
                render()
                state.update { $0.needsRedraw = false }
            }
        }
        return 0
    }

    // MARK: input

    private func handle(_ key: Key) {
        let mode = state.snapshot.mode
        switch mode {
        case .list: handleListKey(key)
        case .filter: handleFilterKey(key)
        case .password: handlePasswordKey(key)
        case .help: handleHelpKey(key)
        }
    }

    private func handleListKey(_ key: Key) {
        let snap = state.snapshot
        let visible = visibleEntries(snap)
        switch key {
        case .up, .char("k"):
            move(by: -1, visible: visible)
        case .down, .char("j"):
            move(by: 1, visible: visible)
        case .pageUp:
            move(by: -max(1, term.rows - 8), visible: visible)
        case .pageDown:
            move(by: max(1, term.rows - 8), visible: visible)
        case .home, .char("g"):
            select(index: 0, visible: visible)
        case .end, .char("G"):
            select(index: visible.count - 1, visible: visible)
        case .enter:
            connectSelected()
        case .char("r"):
            engine.scan()
        case .char("/"):
            state.update {
                $0.mode = .filter
                $0.filterDraft = $0.query
                $0.needsRedraw = true
            }
        case .tab:
            state.update {
                $0.bandFilter = $0.bandFilter.next
                $0.selectedIndex = 0
                $0.needsRedraw = true
            }
        case .char("s"):
            state.update {
                $0.sort = $0.sort.next
                $0.needsRedraw = true
            }
        case .char("?"):
            state.update {
                $0.mode = .help
                $0.needsRedraw = true
            }
        case .char("q"), .char("Q"), .ctrl("c"), .ctrl("d"):
            state.update { $0.quit = true }
        default:
            break
        }
    }

    private func handleFilterKey(_ key: Key) {
        switch key {
        case .escape:
            state.update {
                $0.mode = .list
                $0.filterDraft = ""
                $0.needsRedraw = true
            }
        case .enter:
            state.update {
                $0.mode = .list
                $0.query = $0.filterDraft
                $0.selectedIndex = 0
                $0.needsRedraw = true
            }
        case .backspace:
            state.update {
                if !$0.filterDraft.isEmpty { $0.filterDraft.removeLast() }
                $0.needsRedraw = true
            }
        case .ctrl("u"):
            state.update {
                $0.filterDraft = ""
                $0.needsRedraw = true
            }
        case .char(let character):
            state.update {
                $0.filterDraft.append(character)
                $0.needsRedraw = true
            }
        case .ctrl("c"):
            state.update { $0.quit = true }
        default:
            break
        }
    }

    private func handlePasswordKey(_ key: Key) {
        switch key {
        case .escape:
            state.update {
                $0.mode = .list
                $0.passwordDraft = ""
                $0.passwordTarget = nil
                $0.passwordHint = ""
                $0.status = "Connect cancelled"
                $0.statusIsError = false
                $0.needsRedraw = true
            }
        case .enter:
            let snap = state.snapshot
            guard let target = snap.passwordTarget else { return }
            let password = snap.passwordDraft
            state.update {
                $0.mode = .list
                $0.passwordDraft = ""
                $0.passwordTarget = nil
                $0.needsRedraw = true
            }
            engine.connect(entry: target, password: password.isEmpty ? nil : password)
        case .backspace:
            state.update {
                if !$0.passwordDraft.isEmpty { $0.passwordDraft.removeLast() }
                $0.needsRedraw = true
            }
        case .ctrl("u"):
            state.update {
                $0.passwordDraft = ""
                $0.needsRedraw = true
            }
        case .char(let character):
            state.update {
                $0.passwordDraft.append(character)
                $0.needsRedraw = true
            }
        case .ctrl("c"):
            state.update { $0.quit = true }
        default:
            break
        }
    }

    private func handleHelpKey(_ key: Key) {
        switch key {
        case .escape, .enter, .char("?"), .char("q"):
            state.update {
                $0.mode = .list
                $0.needsRedraw = true
            }
        case .ctrl("c"):
            state.update { $0.quit = true }
        default:
            break
        }
    }

    private func move(by delta: Int, visible: [NetworkEntry]) {
        guard !visible.isEmpty else { return }
        let current = state.snapshot.selectedIndex
        select(index: current + delta, visible: visible)
    }

    private func select(index: Int, visible: [NetworkEntry]) {
        guard !visible.isEmpty else { return }
        let clamped = max(0, min(visible.count - 1, index))
        let key = visible[clamped].identityKey
        state.update {
            $0.selectedIndex = clamped
            $0.selectedKey = key
            $0.needsRedraw = true
        }
    }

    private func connectSelected() {
        let snap = state.snapshot
        let visible = visibleEntries(snap)
        guard visible.indices.contains(snap.selectedIndex) else { return }
        let entry = visible[snap.selectedIndex]
        if entry.isCurrent {
            state.update {
                $0.status = "\(entry.displaySSID) is already the current network"
                $0.statusIsError = false
                $0.needsRedraw = true
            }
            return
        }
        if entry.isOpen {
            engine.connect(entry: entry, password: "")
            return
        }
        if entry.isSaved, let ssid = entry.ssid {
            switch Keychain.password(for: ssid) {
            case .found(let password):
                state.update {
                    $0.status = "Using the saved credential for \(entry.displaySSID)"
                    $0.needsRedraw = true
                }
                engine.connect(entry: entry, password: password)
            case .missing, .denied, .failed:
                promptForPassword(entry, hint: "Saved network. Enter with an empty field to use the system credential.")
            }
            return
        }
        promptForPassword(entry, hint: "Enter the Wi-Fi password. Esc cancels.")
    }

    private func promptForPassword(_ entry: NetworkEntry, hint: String) {
        state.update {
            $0.mode = .password
            $0.passwordTarget = entry
            $0.passwordDraft = ""
            $0.passwordHint = hint
            $0.status = "Waiting for a password for \(entry.displaySSID)"
            $0.statusIsError = false
            $0.needsRedraw = true
        }
    }

    // MARK: derived list

    private func visibleEntries(_ snap: UIState) -> [NetworkEntry] {
        var list = snap.entries
        if snap.bandFilter != .all {
            list = list.filter { snap.bandFilter.matches($0) }
        }
        if !snap.query.isEmpty {
            list = filterEntries(list, query: snap.query)
        }
        return sortEntries(list, by: snap.sort)
    }

    // MARK: rendering

    private func columnValue(_ entry: NetworkEntry, title: String) -> (String, String) {
        switch title {
        case "BAND":
            return (entry.band.rawValue, Style.band(entry.band))
        case "SSID":
            let name = entry.displaySSID
            if entry.ssid == nil { return (name, Style.grey) }
            if entry.isCurrent { return (name, Style.current) }
            return (name, "")
        case "BSSID":
            let text = entry.displayBSSID
            return (text, entry.bssid == nil ? Style.grey : "")
        case "CH":
            return (entry.channel.map(String.init) ?? "-", "")
        case "W":
            return (entry.widthMHz.map(String.init) ?? "-", "")
        case "RSSI":
            let bars = signalBars(entry.rssi)
            let dbm = entry.rssi.map(String.init) ?? "-"
            return ("\(bars) \(dbm)", entry.rssi == nil ? Style.grey : "")
        case "SEC":
            return (entry.security, entry.security == "?" ? Style.grey : "")
        default:
            var flags = ""
            if entry.isCurrent { flags += "*" }
            if entry.isSaved { flags += "S" }
            if entry.isOfflineSaved { flags += "-" }
            return (flags, entry.isCurrent ? Style.current : Style.dim)
        }
    }

    private func row(_ entry: NetworkEntry, columns: [TableLayout.Column], selected: Bool, connecting: Bool) -> String {
        var styled = ""
        let marker = selected ? "\u{25B8}" : " "
        styled += (selected ? Style.cursor : "") + marker + Style.reset + " "
        for column in columns {
            let (text, style) = columnValue(entry, title: column.title)
            let padded = Display.pad(text, width: column.width, alignRight: column.rightAligned)
            styled += style + padded + Style.reset + " "
        }
        // A trailing space is dropped so the selected background does not leave
        // a ragged edge.
        if selected {
            styled = Style.selectedRow + styled + Style.reset
        }
        if connecting { styled = Style.selectedRow + Style.warn + styled + Style.reset }
        return styled
    }

    private func spinnerGlyph(_ frame: Int) -> String {
        let glyphs = ["\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"]
        return glyphs[frame % glyphs.count]
    }

    private func header(_ snap: UIState) -> String {
        // The header must never wrap: anything that does not fit is dropped
        // from the right, least important first, instead of pushing the whole
        // frame down a line.
        var parts: [String] = []
        parts.append(Style.bold + "wifind" + Style.reset)
        parts.append(Style.grey + snap.ifaceName + Style.reset)
        if snap.scanning {
            parts.append(Style.warn + spinnerGlyph(snap.spinner) + " scanning" + Style.reset)
        } else {
            parts.append("\(snap.rawCount) APs")
        }
        var bandLabel = ""
        for filter in BandFilter.allCases {
            let name = filter == .all ? "all" : filter.rawValue
            if filter == snap.bandFilter {
                let colour = filter == .all ? Style.bold : Style.bold + Style.band(bandForFilter(filter))
                bandLabel += colour + name + Style.reset + " "
            } else {
                bandLabel += Style.grey + name + Style.reset + " "
            }
        }
        var optional: [String] = ["band " + bandLabel.trimmingCharacters(in: .whitespaces)]
        optional.append("sort \(snap.sort.rawValue)")
        if !snap.query.isEmpty {
            optional.append(Style.warn + "/\(snap.query)" + Style.reset)
        }
        optional.append(Style.grey + TUIApp.clock.string(from: Date()) + Style.reset)
        for part in optional {
            let candidate = parts + [part]
            if TUIApp.assembledWidth(candidate) <= term.cols {
                parts.append(part)
            }
        }
        return TUIApp.assemble(parts)
    }

    /// One cached formatter: building one per frame at ten frames a second is
    /// pure waste.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let separator = Style.grey + " \u{2502} " + Style.reset

    private static func assemble(_ parts: [String]) -> String {
        return " " + parts.joined(separator: Style.grey + " \u{2502} " + Style.reset) + " "
    }

    private static func assembledWidth(_ parts: [String]) -> Int {
        Display.visibleWidth(assemble(parts))
    }

    private func bandForFilter(_ filter: BandFilter) -> Band {
        switch filter {
        case .all: return .unknown
        case .ghz2: return .ghz2
        case .ghz5: return .ghz5
        case .ghz6: return .ghz6
        }
    }

    private func columnHeader(_ snap: UIState) -> String {
        let cols = TableLayout(width: term.cols).columns
        var text = "  "
        for column in cols {
            var title = column.title
            if title == snap.sort.rawValue { title += "\u{25BC}" }
            let padded = Display.pad(title, width: column.width, alignRight: column.rightAligned)
            text += padded + " "
        }
        return Style.dim + text + Style.reset
    }

    private func detail(_ snap: UIState, entry: NetworkEntry?) -> String {
        guard let entry else { return Style.grey + " no access point selected" + Style.reset }
        var parts: [String] = []
        parts.append(Style.band(entry.band) + entry.band.longName + Style.reset)
        if let channel = entry.channel {
            var text = "ch \(channel)"
            if let width = entry.widthMHz { text += " (\(width) MHz)" }
            parts.append(text)
        }
        parts.append(entry.security)
        if let phy = entry.phyMode { parts.append(phy) }
        if let rssi = entry.rssi { parts.append("\(rssi) dBm") }
        if let noise = entry.noise { parts.append("noise \(noise) dBm") }
        if entry.isCurrent { parts.append(Style.current + "current" + Style.reset) }
        if entry.isSaved { parts.append("saved") }
        if entry.isOfflineSaved { parts.append(Style.warn + "not in range" + Style.reset) }
        if entry.bssid == nil, entry.ssid != nil { parts.append(Style.grey + "BSSID hidden by macOS" + Style.reset) }
        return " " + parts.joined(separator: Style.grey + " \u{00B7} " + Style.reset)
    }

    private func statusLine(_ snap: UIState) -> String {
        var text = " "
        if snap.connectingKey != nil {
            text += Style.warn + spinnerGlyph(snap.spinner) + " " + snap.status + Style.reset
        } else if snap.statusIsError {
            text += Style.error + snap.status + Style.reset
        } else {
            text += Style.ok + snap.status + Style.reset
        }
        return text
    }

    /// Wraps the first note to the terminal and styles every line. A note is
    /// the only explanation the user gets when macOS hides the names, so it is
    /// worth two lines rather than an ellipsis.
    private func noteLines(_ snap: UIState) -> [String] {
        guard let note = snap.notes.first else { return [] }
        let wrapped = Display.wrap(note, columns: max(20, term.cols - 4), maxLines: 2)
        return wrapped.enumerated().map { index, line in
            " " + Style.warn + (index == 0 ? " ! " : "   ") + line + Style.reset
        }
    }

    private func footer() -> String {
        // Same rule as the header: show the keys that fit, never wrap.
        let hints = [
            "\u{2191}\u{2193} move", "\u{23CE} connect", "r rescan", "/ filter",
            "tab band", "s sort", "? help", "q quit",
        ]
        var text = ""
        for hint in hints {
            let candidate = text.isEmpty ? hint : text + "  " + hint
            if Display.width(candidate) + 2 <= term.cols {
                text = candidate
            }
        }
        if text.isEmpty { text = "q quit" }
        return Style.grey + " " + text + Style.reset
    }

    private func paint(_ lines: [String]) {
        // Clamp, then repaint only the rows that changed.
        //
        // Two failure modes are fixed here. Writing a line wider than the
        // terminal makes it wrap, which shifts every following row and makes
        // the whole screen jump; and rewriting all rows ten times a second for
        // the spinner is what made it flicker. Absolute cursor addressing plus
        // a per-row diff removes both: one row changes, one row is written.
        let height = max(1, term.rows)
        var frame = lines.prefix(height).map { Display.truncateVisible($0, width: term.cols) }
        while frame.count < min(height, lastFrame.count) { frame.append("") }

        var out = "\u{1B}[?2026h"
        var wrote = false
        for row in 0..<max(frame.count, lastFrame.count) {
            let newLine = row < frame.count ? frame[row] : ""
            let oldLine = row < lastFrame.count ? lastFrame[row] : ""
            if newLine == oldLine { continue }
            out += "\u{1B}[\(row + 1);1H" + newLine + "\u{1B}[K"
            wrote = true
        }
        out += "\u{1B}[?2026l"
        lastFrame = frame
        if wrote { term.write(out) }
    }

    /// Last frame as it was written to the terminal, for the diff above.
    private var lastFrame: [String] = []

    private func render() {
        let snap = state.snapshot
        let filtered = visibleEntries(snap)
        var lines: [String] = []
        lines.append(header(snap))

        switch snap.mode {
        case .help:
            lines.append(contentsOf: helpLines(snap))
            paint(lines)
            return
        case .list, .filter, .password:
            break
        }

        lines.append(columnHeader(snap))

        let notes = noteLines(snap)
        lines.append(contentsOf: notes)

        let chrome = 3 // detail + status + footer
        let listRows = max(1, term.rows - lines.count - chrome)

        // Keep the selection on the same access point across rescans.
        var selectedIndex = snap.selectedIndex
        if let key = snap.selectedKey, let index = filtered.firstIndex(where: { $0.identityKey == key }) {
            selectedIndex = index
        }
        selectedIndex = max(0, min(max(0, filtered.count - 1), selectedIndex))

        var offset = 0
        if selectedIndex >= listRows { offset = selectedIndex - listRows + 1 }

        if filtered.isEmpty {
            let message = snap.scanning ? "Scanning..." : "No access points to show"
            lines.append(" " + Style.grey + message + Style.reset)
            for _ in 1..<listRows { lines.append("") }
        } else {
            let window = filtered[offset..<min(filtered.count, offset + listRows)]
            for (indexInWindow, entry) in window.enumerated() {
                let absolute = offset + indexInWindow
                lines.append(
                    row(
                        entry,
                        columns: TableLayout(width: term.cols).columns,
                        selected: absolute == selectedIndex,
                        connecting: snap.connectingKey == entry.identityKey
                    )
                )
            }
            for _ in window.count..<listRows { lines.append("") }
        }

        let selectedEntry = filtered.indices.contains(selectedIndex) ? filtered[selectedIndex] : nil
        lines.append(detail(snap, entry: selectedEntry))
        lines.append(statusLine(snap))

        if snap.mode == .password {
            paint(overlayPassword(on: lines, snap: snap))
            return
        }
        lines.append(footer())
        if selectedIndex != snap.selectedIndex {
            state.update { $0.selectedIndex = selectedIndex }
        }
        paint(lines)
    }

    private func overlayPassword(on lines: [String], snap: UIState) -> [String] {
        var output = lines
        // Never wider than the terminal, or the box itself would wrap and undo
        // the point of drawing it.
        let boxWidth = max(20, min(72, term.cols - 2))
        let inner = boxWidth - 4
        let target = snap.passwordTarget?.displaySSID ?? "network"
        let masked = String(repeating: "*", count: Display.width(snap.passwordDraft))
        let content: [String] = [
            "\u{250C}" + String(repeating: "\u{2500}", count: boxWidth - 2) + "\u{2510}",
            "\u{2502} " + Style.bold + Display.pad("Connect to \(target)", width: inner) + Style.reset + " \u{2502}",
            "\u{2502} " + Display.pad("Password: \(masked)", width: inner) + " \u{2502}",
            "\u{2502} " + Style.grey + Display.pad(snap.passwordHint, width: inner) + Style.reset + " \u{2502}",
            "\u{2514}" + String(repeating: "\u{2500}", count: boxWidth - 2) + "\u{2518}",
        ]
        let start = max(0, (output.count - content.count) / 2)
        let padding = String(repeating: " ", count: max(0, (term.cols - boxWidth) / 2))
        for (index, line) in content.enumerated() where start + index < output.count {
            output[start + index] = padding + line
        }
        return output
    }

    private func helpLines(_ snap: UIState) -> [String] {
        let advice = LocationAdvice.fix(
            for: snap.locationStatus,
            bundled: Bundle.main.bundleIdentifier != nil,
            parent: ProcessInfo.processInfo.environment["TERM_PROGRAM"]
        )
        var lines: [String] = []
        lines.append("")
        lines.append(Style.bold + "  Keys" + Style.reset)
        lines.append("   \u{2191} \u{2193} / j k     move the selection")
        lines.append("   enter        connect to the selected network (or say that you already are)")
        lines.append("   r            rescan")
        lines.append("   /            filter by SSID or BSSID (enter applies, esc clears)")
        lines.append("   tab          cycle band filter: all, 2.4G, 5G, 6G")
        lines.append("   s            cycle sort: RSSI, SSID, CH, BAND, SEC")
        lines.append("   ?            close this help")
        lines.append("   q            quit")
        lines.append("")
        lines.append(Style.bold + "  Environment" + Style.reset)
        lines.append("   interface        \(snap.ifaceName)")
        lines.append("   location         \(LocationGate.label(for: snap.locationStatus))")
        lines.append("   scan route       \(snap.route == .helper ? "Wifind.app bundle" : "this process")")
        lines.append("   last scan        \(snap.rawCount) access points, \(snap.ssidVisible) with SSID, \(snap.bssidVisible) with BSSID")
        lines.append("   favorites        \(snap.entries.filter { $0.isSaved }.count) known networks in the list")
        lines.append("")
        lines.append(Style.bold + "  Notes" + Style.reset)
        lines.append("   \(advice)")
        for note in snap.notes {
            lines.append("   \(note)")
        }
        lines.append("")
        lines.append(Style.grey + "   press ? or esc to go back" + Style.reset)
        return lines
    }
}

/// Entry point used by `wifind` when no subcommand is given.
func runTUI(interfaceName: String?, allowsHelper: Bool = true) -> Int32 {
    guard let term = Terminal() else {
        FileHandle.standardError.write(
            Data("wifind: the interactive UI needs a terminal (stdin and stdout must be a TTY).\n".utf8)
        )
        return 2
    }
    return TUIApp(term: term, interfaceName: interfaceName, allowsHelper: allowsHelper).run()
}
