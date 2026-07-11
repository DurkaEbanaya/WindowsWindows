import AppKit
import Darwin
import Foundation

private enum SignalMarker: UInt8 {
    case terminate = 1
    case suspend = 2
}

private final class TerminalSession {
    private var original = termios()
    private(set) var isRaw = false
    private var signalSources: [DispatchSourceSignal] = []
    private let signalPipe: (read: Int32, write: Int32)

    init() throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        signalPipe = (descriptors[0], descriptors[1])
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            close(descriptors[0])
            close(descriptors[1])
            throw TUIError.notInteractive
        }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        installSignalSources()
        try enterRawMode()
    }

    deinit {
        restore()
        signalSources.forEach { $0.cancel() }
        close(signalPipe.read)
        close(signalPipe.write)
    }

    func enterRawMode() throws {
        guard !isRaw else { return }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_cc.6 = 1 // VMIN
        raw.c_cc.5 = 0 // VTIME
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        isRaw = true
        writeOutput("\u{001B}[?25l")
    }

    func restore(showCursor: Bool = true, clearScreen: Bool = false) {
        if isRaw {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            isRaw = false
        }
        var output = "\u{001B}[0m"
        if showCursor { output += "\u{001B}[?25h" }
        if clearScreen { output += "\u{001B}[2J\u{001B}[H" }
        writeOutput(output)
    }

    func readKey() throws -> InputKey {
        while true {
            let key: InputKey
            do {
                key = try TerminalInput.readKey(signalDescriptor: signalPipe.read)
            } catch TUIError.suspendRequested {
                try suspend()
                continue
            }
            switch key {
            case .character("\u{1A}"):
                try suspend()
            case let key:
                return key
            }
        }
    }

    func readLine(prompt: String) throws -> String {
        writeOutput("\u{001B}[2J\u{001B}[H\(prompt)")
        var value = ""
        while true {
            switch try readKey() {
            case .interrupt:
                throw TUIError.interrupted
            case .character("\r"), .character("\n"):
                writeOutput("\r\n")
                return value
            case .character("\u{7F}"), .character("\u{8}"):
                guard !value.isEmpty else { continue }
                value.removeLast()
                writeOutput("\u{8} \u{8}")
            case .character(let character) where "0123456789.+-eE".contains(character):
                value.append(character)
                writeOutput(String(character))
            default:
                break
            }
        }
    }

    private func installSignalSources() {
        for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            let writeDescriptor = signalPipe.write
            source.setEventHandler {
                var marker = number == SIGTSTP
                    ? SignalMarker.suspend.rawValue
                    : SignalMarker.terminate.rawValue
                _ = Darwin.write(writeDescriptor, &marker, 1)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func suspend() throws {
        restore(showCursor: true, clearScreen: false)
        guard kill(getpid(), SIGSTOP) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try enterRawMode()
    }
}

private enum InputKey {
    case interrupt
    case up
    case down
    case space
    case character(Character)
    case unknown
}

private struct TerminalInput {
    static func readKey(signalDescriptor: Int32) throws -> InputKey {
        let first = try readByte(signalDescriptor: signalDescriptor, timeoutMilliseconds: -1)
        if first == 0x1B {
            guard let second = try readOptionalByte(
                signalDescriptor: signalDescriptor,
                timeoutMilliseconds: 40
            ) else { return .unknown }
            guard let third = try readOptionalByte(
                signalDescriptor: signalDescriptor,
                timeoutMilliseconds: 40
            ) else { return .unknown }
            if second == 0x5B, third == 0x41 { return .up }
            if second == 0x5B, third == 0x42 { return .down }
            return .unknown
        }
        if first == 0x03 { return .interrupt }
        if first == 0x20 { return .space }
        guard first < 0x80, let scalar = UnicodeScalar(Int(first)) else { return .unknown }
        return .character(Character(scalar))
    }

    private static func readByte(signalDescriptor: Int32, timeoutMilliseconds: Int32) throws -> UInt8 {
        guard let byte = try readOptionalByte(
            signalDescriptor: signalDescriptor,
            timeoutMilliseconds: timeoutMilliseconds
        ) else { throw TUIError.endOfInput }
        return byte
    }

    private static func readOptionalByte(
        signalDescriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> UInt8? {
        var descriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: signalDescriptor, events: Int16(POLLIN), revents: 0)
        ]
        while true {
            let result = poll(&descriptors, nfds_t(descriptors.count), timeoutMilliseconds)
            if result == 0 { return nil }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
                var marker: UInt8 = 0
                _ = read(signalDescriptor, &marker, 1)
                if marker == SignalMarker.suspend.rawValue {
                    throw TUIError.suspendRequested
                }
                throw TUIError.interrupted
            }
            guard descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 else { continue }
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 { return byte }
            if count == 0 { throw TUIError.endOfInput }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}

private enum TUIError: LocalizedError {
    case notInteractive
    case endOfInput
    case interrupted
    case suspendRequested
    case invalidNumber(String)
    case configurationChangedExternally

    var errorDescription: String? {
        switch self {
        case .notInteractive: return "wwctl requires an interactive terminal"
        case .endOfInput: return "terminal input ended"
        case .interrupted: return "interrupted"
        case .suspendRequested: return "suspend requested"
        case .invalidNumber(let value): return "invalid number: \(value)"
        case .configurationChangedExternally:
            return "configuration changed externally; press r to reload before saving"
        }
    }
}

private final class SettingsTUI {
    private let store: ConfigStore
    private let terminal: TerminalSession
    private var config: ShelfConfig
    private var loadedConfig: ShelfConfig
    private var rows: [ApplicationCatalogRow]
    private var selectedIndex = 0
    private var status = ""
    private var isDirty = false

    init(store: ConfigStore, terminal: TerminalSession) throws {
        self.store = store
        self.terminal = terminal
        self.config = try store.load()
        self.loadedConfig = config
        self.rows = ApplicationCatalog.load(configuredIDs: config.bundleIdentifiers)
    }

    func run() throws {
        defer { terminal.restore(showCursor: true, clearScreen: false) }
        while true {
            render()
            let key = try terminal.readKey()
            do {
                try handle(key)
            } catch TUIError.interrupted {
                throw TUIError.interrupted
            } catch {
                status = error.localizedDescription
            }
            if shouldExit { return }
        }
    }

    private var shouldExit = false

    private func handle(_ key: InputKey) throws {
        switch key {
            case .interrupt:
                throw TUIError.interrupted
            case .up, .character("k"):
                if !rows.isEmpty { selectedIndex = max(0, selectedIndex - 1) }
            case .down, .character("j"):
                if !rows.isEmpty { selectedIndex = min(rows.count - 1, selectedIndex + 1) }
            case .space:
                toggleSelectedApplication()
            case .character("m"):
                config.scopeMode = config.scopeMode == .allExceptListed ? .onlyListed : .allExceptListed
                isDirty = true
                status = "Scope mode changed"
            case .character("f"):
                try editRefreshInterval()
            case .character("p"):
                try editSnapshotInterval()
            case .character("r"):
                if isDirty {
                    status = "Unsaved changes: press s to save, or R to discard and reload"
                } else {
                    try reload()
                }
            case .character("R"):
                try reload()
            case .character("s"):
                try save()
            case .character("q"):
                if isDirty {
                    status = "Unsaved changes: press s to save, or Q to discard"
                } else {
                    shouldExit = true
                }
            case .character("Q"):
                shouldExit = true
            default:
                break
        }
    }

    private func toggleSelectedApplication() {
        guard rows.indices.contains(selectedIndex) else { return }
        let id = rows[selectedIndex].bundleIdentifier
        if let index = config.bundleIdentifiers.firstIndex(of: id) {
            config.bundleIdentifiers.remove(at: index)
        } else {
            config.bundleIdentifiers.append(id)
        }
        isDirty = true
        status = "Updated \(rows[selectedIndex].name); press s to save"
    }

    private func editRefreshInterval() throws {
        let value = try promptNumber(label: "Refresh interval", current: config.refreshInterval)
        var candidate = config
        candidate.refreshInterval = value
        _ = try candidate.validated()
        config = candidate
        isDirty = true
        status = "Refresh interval changed"
    }

    private func editSnapshotInterval() throws {
        let value = try promptNumber(label: "Snapshot interval", current: config.snapshotInterval)
        var candidate = config
        candidate.snapshotInterval = value
        _ = try candidate.validated()
        config = candidate
        isDirty = true
        status = "Snapshot interval changed"
    }

    private func promptNumber(label: String, current: TimeInterval) throws -> TimeInterval {
        let line = try terminal.readLine(prompt: "\(label) in seconds [\(format(current))]: ")
        if line.isEmpty { return current }
        guard let value = TimeInterval(line) else { throw TUIError.invalidNumber(line) }
        return value
    }

    private func reload() throws {
        config = try store.load()
        loadedConfig = config
        rows = ApplicationCatalog.load(configuredIDs: config.bundleIdentifiers)
        selectedIndex = min(selectedIndex, max(0, rows.count - 1))
        isDirty = false
        status = "Reloaded from \(store.configURL.path)"
    }

    private func save() throws {
        let desired = try config.validated()
        config = try store.update { current in
            guard current == loadedConfig else {
                throw TUIError.configurationChangedExternally
            }
            current = desired
        }
        loadedConfig = config
        rows = ApplicationCatalog.load(configuredIDs: config.bundleIdentifiers)
        isDirty = false
        status = "Saved; WindowsWindows will apply changes on its next refresh"
    }

    private func render() {
        let listMeaning = config.scopeMode == .allExceptListed ? "excluded" : "included"
        var output = "\u{001B}[2J\u{001B}[H"
        output += "\u{001B}[1mWindowsWindows Settings\u{001B}[0m\n\n"
        output += "Mode: \u{001B}[1m\(config.scopeMode.rawValue)\u{001B}[0m  (m: switch)\n"
        output += "Refresh: \(format(config.refreshInterval))s (f: edit)   "
        output += "Snapshot: \(format(config.snapshotInterval))s (p: edit)\n"
        output += "Space toggles whether an app is \(listMeaning). Running apps are marked ●.\n\n"

        if rows.isEmpty {
            output += "  No configurable applications are running or listed.\n"
        } else {
            let terminalRows = terminalSize().rows
            let visibleCount = max(1, terminalRows - 10)
            let start = min(
                max(0, selectedIndex - visibleCount / 2),
                max(0, rows.count - visibleCount)
            )
            let end = min(rows.count, start + visibleCount)
            for index in start..<end {
                let row = rows[index]
                let selected = index == selectedIndex
                let listed = config.bundleIdentifiers.contains(row.bundleIdentifier)
                output += selected ? "\u{001B}[7m" : ""
                output += "\(selected ? ">" : " ") [\(listed ? "x" : " ")] \(row.isRunning ? "●" : "○") "
                output += "\(terminalText(row.name))  \u{001B}[2m\(terminalText(row.bundleIdentifier))\u{001B}[0m"
                output += selected ? "\u{001B}[0m" : ""
                output += "\n"
            }
        }
        output += "\n↑/↓ or j/k navigate  s save  r reload  q quit  R/Q discard\n"
        if !status.isEmpty { output += "\n\u{001B}[33m\(terminalText(status))\u{001B}[0m\n" }
        writeOutput(output)
    }

    private func format(_ value: TimeInterval) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private func terminalSize() -> (columns: Int, rows: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 else {
        return (80, 24)
    }
    return (max(20, Int(size.ws_col)), max(12, Int(size.ws_row)))
}

private func terminalText(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F
    }
    return String(String.UnicodeScalarView(scalars))
}

private func writeOutput(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
}

@main
private struct WWCtlMain {
    static func main() {
        do {
            let store = try ConfigStore()
            let terminal = try TerminalSession()
            try SettingsTUI(store: store, terminal: terminal).run()
        } catch {
            writeOutput("wwctl: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }
    }
}
