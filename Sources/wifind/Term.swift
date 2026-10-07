import Foundation

/// Keys the UI understands, decoded from raw terminal bytes.
public enum Key: Equatable {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, escape, tab, backspace, delete
    case char(Character)
    case ctrl(Character)
    case unknown
}

// Signal flags. `signal(2)` handlers cannot capture context, so the state is
// global and read from the render loop.
private var resizePending: sig_atomic_t = 0
private var quitPending: sig_atomic_t = 0

private func onResize(_: Int32) { resizePending = 1 }
private func onQuit(_: Int32) { quitPending = 1 }

/// Raw-mode terminal: alt screen, key decoding, measured size, and a single
/// `write` per frame so the UI does not flicker.
public final class Terminal {
    private var original = termios()
    private var rawMode = false
    public private(set) var rows = 24
    public private(set) var cols = 80

    public init?() {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return nil }
        updateSize()
    }

    deinit { restore() }

    public static func installSignalHandlers() {
        signal(SIGWINCH, onResize)
        signal(SIGINT, onQuit)
        signal(SIGTERM, onQuit)
        signal(SIGHUP, onQuit)
    }

    public static var resizePendingFlag: Bool { resizePending != 0 }
    public static var quitPendingFlag: Bool { quitPending != 0 }
    public static func clearResizeFlag() { resizePending = 0 }

    public func updateSize() {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            cols = Int(size.ws_col)
            rows = Int(size.ws_row)
        }
    }

    public func enterRawMode() {
        guard !rawMode else { return }
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
        raw.c_cc.16 = 0 // VMIN
        raw.c_cc.17 = 0 // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawMode = true
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
    }

    public func restore() {
        guard rawMode else { return }
        write("\u{1B}[?25h\u{1B}[0m\u{1B}[?1049l")
        var raw = original
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        rawMode = false
    }

    public func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    /// Waits up to `timeout` for a key. Returns nil on timeout.
    public func readKey(timeout: TimeInterval) -> Key? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(timeout, 5) * 1000))
        let ready = poll(&descriptor, 1, milliseconds)
        guard ready > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { return .ctrl("d") }
        var bytes = Array(buffer[0..<count])
        // A key repeat can split an escape sequence across two reads. Without
        // this grace period the leading ESC would decode as Escape, which
        // cancels the password prompt when the user meant to press an arrow
        // key.
        if bytes.first == 0x1B, !Terminal.isCompleteEscape(bytes) {
            let deadline = Date().addingTimeInterval(0.03)
            while Date() < deadline, !Terminal.isCompleteEscape(bytes) {
                var pending = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                if poll(&pending, 1, 5) <= 0 { continue }
                var extra = [UInt8](repeating: 0, count: 128)
                let extraCount = read(STDIN_FILENO, &extra, extra.count)
                if extraCount > 0 { bytes.append(contentsOf: extra[0..<extraCount]) }
            }
        }
        return Terminal.decode(bytes)
    }

    /// True when the bytes already form a complete escape sequence.
    static func isCompleteEscape(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return true }
        guard first == 0x1B else { return true }
        guard bytes.count >= 2 else { return false }
        guard bytes[1] == 0x5B || bytes[1] == 0x4F else { return true }
        // CSI runs until a byte in the final range, 0x40-0x7E.
        return bytes.dropFirst(2).contains { $0 >= 0x40 && $0 <= 0x7E }
    }

    static func decode(_ bytes: [UInt8]) -> Key {
        guard let first = bytes.first else { return .unknown }
        if first == 0x1B {
            guard bytes.count > 1 else { return .escape }
            if bytes[1] == 0x5B || bytes[1] == 0x4F { // CSI / SS3
                let suffix = bytes.count > 2 ? bytes[2] : 0
                switch suffix {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home
                case 0x46: return .end
                case 0x35 where bytes.count > 3 && bytes[3] == 0x7E: return .pageUp
                case 0x36 where bytes.count > 3 && bytes[3] == 0x7E: return .pageDown
                case 0x33 where bytes.count > 3 && bytes[3] == 0x7E: return .delete
                default: return .unknown
                }
            }
            return .escape
        }
        switch first {
        case 0x0D, 0x0A: return .enter
        case 0x09: return .tab
        case 0x7F, 0x08: return .backspace
        case 0x03: return .ctrl("c")
        case 0x04: return .ctrl("d")
        case 0x0C: return .ctrl("l")
        case 0x1A: return .ctrl("z")
        default: break
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if let character = text.first { return .char(character) }
        return .unknown
    }
}
