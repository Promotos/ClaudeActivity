import AppKit
import Foundation

// ============================================================================
// ClaudeActivity — shows in the macOS menu bar whether Claude is exchanging tokens.
//
// Icon: two stacked arrows (narrow, to save space in the menu bar)
//   ▲ top    = outbound (prompt/tokens going out)
//   ▼ bottom = inbound (response/tokens coming in)
//
// Two signals:
//   1) Per-process network traffic (nettop, delta mode) for Claude Desktop
//      and Claude Code (node/claude CLI) — separated by direction.
//   2) Changes to ~/.claude/projects/**/*.jsonl as a secondary signal for Claude Code.
// ============================================================================

// MARK: - Configuration

enum Config {
    /// How often the UI/file poll runs.
    static let pollInterval: TimeInterval = 1.0
    /// How often the process list is re-read.
    static let processScanInterval: TimeInterval = 5.0
    /// Interval between two nettop samples, in seconds.
    static let sampleInterval: TimeInterval = 1.0
    /// Samples per nettop run; the process is restarted afterwards (see NetworkMonitor).
    static let samplesPerRun = 1800
    /// How old a sample may be and still count as "current".
    static let sampleFreshness: TimeInterval = 3.0
    /// Lower bound that hides keep-alives and idle telemetry
    /// (bytes per second, summed over all processes of a source).
    static let thresholdIn: Double = 250
    static let thresholdOut: Double = 150
    /// How long an arrow keeps glowing after the last hit.
    static let activityHold: TimeInterval = 2.0
    /// How fresh a .jsonl change must be to count as activity.
    static let fileFreshness: TimeInterval = 3.0
    /// Blink rate of the arrows.
    static let pulseInterval: TimeInterval = 0.4

    // Icon geometry and opacity
    static let arrowsWidth: CGFloat = 11
    static let textGap: CGFloat = 2
    static let iconHeight: CGFloat = 18
    static let arrowPointSize: CGFloat = 8
    static let ratePointSize: CGFloat = 8
    static let sleepPointSize: CGFloat = 11
    /// Opacity of the "zzz" in the idle state.
    static let sleepAlpha: CGFloat = 0.55
    /// Opacity of the inactive arrow while the other direction blinks.
    static let idleArrowAlpha: CGFloat = 0.25
    /// Dark phase of the blink.
    static let blinkLowAlpha: CGFloat = 0.15
}

enum Source: String, CaseIterable {
    case desktop
    case code

    var label: String {
        switch self {
        case .desktop: return "Claude Desktop"
        case .code: return "Claude Code"
        }
    }

    var color: NSColor {
        switch self {
        case .desktop: return NSColor.systemBlue
        case .code: return NSColor.systemGreen
        }
    }
}

enum Direction: String, CaseIterable {
    case outbound  // sent     ▲
    case inbound   // received ▼

    var label: String {
        switch self {
        case .outbound: return "↑"
        case .inbound: return "↓"
        }
    }
}

// MARK: - Helpers

@discardableResult
func runShell(_ launchPath: String, _ args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// Minimal log to ~/Library/Logs/ClaudeActivity.log — so that after the app
/// disappears it is still possible to tell what happened last.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeActivity.log")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

struct Key: Hashable {
    let source: Source
    let direction: Direction
}

// MARK: - Activity state

final class ActivityTracker {
    private var lastSeen: [Key: Date] = [:]
    private var lastBytes: [Key: Double] = [:]
    private var totals: [Key: Double] = [:]
    private var lastSample: [Key: (Date, Double)] = [:]
    private let lock = NSLock()

    /// Sums up all measured traffic — including traffic below the activity threshold.
    func accumulate(_ source: Source, _ direction: Direction, bytes: Double) {
        guard bytes > 0 else { return }
        let key = Key(source: source, direction: direction)
        lock.lock()
        totals[key, default: 0] += bytes
        lock.unlock()
    }

    /// Current rate for the display — independent of the activity threshold.
    func setRate(_ source: Source, _ direction: Direction, bytes: Double) {
        let key = Key(source: source, direction: direction)
        lock.lock()
        lastSample[key] = (Date(), bytes)
        lock.unlock()
    }

    /// Most recently measured rate (bytes/s), provided the sample is fresh.
    /// nil means nothing is arriving from nettop.
    func currentRate(_ source: Source, _ direction: Direction) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let sample = lastSample[Key(source: source, direction: direction)] else { return nil }
        guard Date().timeIntervalSince(sample.0) < Config.sampleFreshness else { return nil }
        return sample.1
    }

    /// Total since app start.
    func total(_ source: Source, _ direction: Direction) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return totals[Key(source: source, direction: direction)] ?? 0
    }

    func mark(_ source: Source, _ direction: Direction, bytes: Double) {
        let key = Key(source: source, direction: direction)
        lock.lock()
        lastSeen[key] = Date()
        lastBytes[key] = bytes
        lock.unlock()
    }

    func isActive(_ source: Source, _ direction: Direction) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fresh(Key(source: source, direction: direction))
    }

    func isActive(_ direction: Direction) -> Bool {
        Source.allCases.contains { isActive($0, direction) }
    }

    func isActive(_ source: Source) -> Bool {
        Direction.allCases.contains { isActive(source, $0) }
    }

    func rate(_ source: Source, _ direction: Direction) -> Double {
        let key = Key(source: source, direction: direction)
        lock.lock()
        defer { lock.unlock() }
        return fresh(key) ? (lastBytes[key] ?? 0) : 0
    }

    /// Which sources are currently active in this direction?
    func activeSources(_ direction: Direction) -> [Source] {
        Source.allCases.filter { isActive($0, direction) }
    }

    /// Time of the last recorded exchange — since app start.
    func lastActivity(_ source: Source) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return Direction.allCases
            .compactMap { lastSeen[Key(source: source, direction: $0)] }
            .max()
    }

    private func fresh(_ key: Key) -> Bool {
        guard let seen = lastSeen[key] else { return false }
        return Date().timeIntervalSince(seen) < Config.activityHold
    }
}

// MARK: - Process scanner (which PID belongs to which source?)

final class ProcessScanner {
    private var map: [Int32: Source] = [:]
    private let lock = NSLock()
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func pidSource(_ pid: Int32) -> Source? {
        lock.lock()
        defer { lock.unlock() }
        return map[pid]
    }

    var counts: (desktop: Int, code: Int) {
        lock.lock()
        defer { lock.unlock() }
        let d = map.values.filter { $0 == .desktop }.count
        let c = map.values.filter { $0 == .code }.count
        return (d, c)
    }

    func scan() {
        guard let out = runShell("/bin/ps", ["-axww", "-o", "pid=,args="]) else { return }
        var newMap: [Int32: Source] = [:]

        for rawLine in out.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let spaceIdx = line.firstIndex(of: " ") else { continue }
            guard let pid = Int32(line[..<spaceIdx]) else { continue }
            if pid == ownPID { continue }

            let args = String(line[line.index(after: spaceIdx)...])
            let lower = args.lowercased()

            if let source = Self.classify(lower) {
                newMap[pid] = source
            }
        }

        lock.lock()
        map = newMap
        lock.unlock()
    }

    /// Maps a command line to a source.
    /// Order matters: Claude Code lives in
    /// ~/Library/Application Support/Claude/claude-code/<version>/claude.app —
    /// that path also contains "claude.app", so it has to be checked first.
    static func classify(_ lower: String) -> Source? {
        if lower.contains("claudeactivity") { return nil }
        if lower.contains("claude usage") { return nil }   // third-party monitor app
        if lower.contains("nettop") || lower.hasPrefix("/bin/ps") { return nil }

        if lower.contains("claude-code")
            || lower.contains(".claude/local")
            || lower.contains("claude/cli.js")
            || (lower.contains("node") && lower.contains("claude")) {
            return .code
        }

        if lower.contains("/claude.app/") || lower.contains("claude helper") {
            return .desktop
        }

        return nil
    }
}

// MARK: - Network monitor (nettop in delta mode)

final class NetworkMonitor {
    // Only touch these on `queue`:
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var samples: [Int32: (date: Date, bytesIn: Double, bytesOut: Double)] = [:]
    private var seenPIDs: Set<Int32> = []
    private var shouldRun = false

    /// A FRESH pipe for every nettop run. Foundation closes the child-side
    /// descriptors when a Process starts; a reused pipe holds a dead descriptor on
    /// the second start, and -[NSConcreteTask launch...] then throws an ObjC
    /// exception → SIGABRT. That is exactly what killed the app after precisely
    /// 30 minutes (= one sample block).
    private var stdinPipe: Pipe?

    private let queue = DispatchQueue(label: "claudeactivity.nettop")

    // Read from the menu (main thread), hence a lock of its own:
    private let stateLock = NSLock()
    private var running = false
    private var errorText: String?

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    var lastError: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return errorText
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock(); running = value; stateLock.unlock()
    }

    private func setError(_ value: String?) {
        stateLock.lock(); errorText = value; stateLock.unlock()
    }

    private let scanner: ProcessScanner
    private let tracker: ActivityTracker

    init(scanner: ProcessScanner, tracker: ActivityTracker) {
        self.scanner = scanner
        self.tracker = tracker
    }

    /// Every state change goes through this serial queue.
    /// Without it the reader thread (pipe), the termination handler and the main
    /// thread would touch samples/seenPIDs/process concurrently — the most likely
    /// cause of a crash during a nettop restart.
    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    /// Synchronous, so that no orphaned nettop is left behind when the app quits.
    func stop() {
        queue.sync {
            self.shouldRun = false
            self.teardown()
        }
    }

    /// Terminates the running nettop process and tears down all handlers cleanly.
    private func teardown() {
        if let handle = pipe?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        pipe = nil
        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning { proc.terminate() }
        }
        process = nil
        stdinPipe = nil
        setRunning(false)
    }

    private func startOnQueue() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/nettop") else {
            setError("nettop not found")
            return
        }

        teardown()
        shouldRun = true
        // The first sample of every run is cumulative, not a delta — relearn it.
        seenPIDs.removeAll()
        samples.removeAll()
        buffer.removeAll()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // -P per process · -d deltas only · -x raw bytes · -n no DNS
        // -s 1 one sample per second
        // -l <n> limited number of samples. Important: "-l 0" does NOT mean
        // "infinite with a pause" — nettop then samples without waiting and
        // saturates a full core. Hence a finite block that is restarted when done.
        proc.arguments = ["-P", "-d", "-x", "-n", "-s", "\(Int(Config.sampleInterval))",
                          "-l", "\(Config.samplesPerRun)",
                          "-J", "bytes_in,bytes_out"]

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        // Important: nettop polls stdin for key presses. If it inherits an stdin
        // from a GUI app that reports EOF immediately (or none at all), that poll
        // spins in an endless loop and burns a whole core.
        // A pipe that stays open blocks cleanly instead of returning EOF.
        let inPipe = Pipe()
        proc.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self = self else { return }
            // Empty data means EOF: detach the handler, otherwise it keeps firing
            // forever and eventually reads from a closed descriptor.
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.consume(chunk) }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                Log.write("nettop exited")
                self.teardown()
                guard self.shouldRun else { return }
                // Sample quota used up → start the next block
                self.queue.asyncAfter(deadline: .now() + 1.0) {
                    guard self.shouldRun else { return }
                    self.startOnQueue()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            pipe = outPipe
            stdinPipe = inPipe   // Keep the write end open for as long as nettop runs
            setRunning(true)
            setError(nil)
            Log.write("nettop started (pid \(proc.processIdentifier))")
        } catch {
            setError("start failed: \(error.localizedDescription)")
            setRunning(false)
            Log.write("nettop failed to start: \(error.localizedDescription)")
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                parse(line)
            }
        }
        if buffer.count > 1_000_000 { buffer.removeAll() }
    }

    /// nettop writes fixed-width columns separated by spaces, not CSV:
    ///     "Claude Helper (Renderer).3511        118        239"
    /// So parse from the right: the last two numbers are bytes_in/bytes_out, and
    /// everything before them belongs to the process name (which may contain spaces).
    private func parse(_ line: String) {
        let tokens = line.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard tokens.count >= 3 else { return }

        guard let bytesOut = Double(tokens[tokens.count - 1]),
              let bytesIn = Double(tokens[tokens.count - 2]) else { return }

        let name = tokens[tokens.count - 3]
        guard let dot = name.lastIndex(of: ".") else { return }
        guard let pid = Int32(name[name.index(after: dot)...]) else { return }
        guard let source = scanner.pidSource(pid) else { return }

        // The first sample of a process holds the total since process start, not
        // the delta — otherwise the counters would jump by megabytes right away.
        if !seenPIDs.contains(pid) {
            seenPIDs.insert(pid)
            samples[pid] = (Date(), 0, 0)
            return
        }

        samples[pid] = (Date(), bytesIn, bytesOut)
        tracker.accumulate(source, .inbound, bytes: bytesIn)
        tracker.accumulate(source, .outbound, bytes: bytesOut)

        aggregate()
    }

    /// Sums the fresh samples of all processes per source.
    /// Necessary because the traffic is spread across several helper processes, and
    /// a single line reading 0 would otherwise overwrite the others in the display.
    private func aggregate() {
        let cutoff = Date().addingTimeInterval(-1.5)
        var sums: [Source: (inbound: Double, outbound: Double)] = [:]

        for (pid, sample) in samples {
            guard sample.date > cutoff, let source = scanner.pidSource(pid) else { continue }
            sums[source, default: (0, 0)].inbound += sample.bytesIn
            sums[source, default: (0, 0)].outbound += sample.bytesOut
        }

        for source in Source.allCases {
            let sum = sums[source] ?? (0, 0)
            tracker.setRate(source, .inbound, bytes: sum.inbound)
            tracker.setRate(source, .outbound, bytes: sum.outbound)
            if sum.inbound >= Config.thresholdIn {
                tracker.mark(source, .inbound, bytes: sum.inbound)
            }
            if sum.outbound >= Config.thresholdOut {
                tracker.mark(source, .outbound, bytes: sum.outbound)
            }
        }

        // Drop leftovers of processes that have exited
        if samples.count > 200 {
            let stale = Date().addingTimeInterval(-60)
            samples = samples.filter { $0.value.date > stale }
        }
    }
}

// MARK: - File monitor for Claude Code transcripts

final class TranscriptMonitor {
    private let tracker: ActivityTracker
    private let root: URL
    private(set) var rootExists: Bool = false
    private(set) var lastFile: String?

    init(tracker: ActivityTracker) {
        self.tracker = tracker
        self.root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        self.rootExists = FileManager.default.fileExists(atPath: root.path)
    }

    func check() {
        guard rootExists else { return }
        let cutoff = Date().addingTimeInterval(-Config.fileFreshness)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if modified > cutoff {
                lastFile = url.deletingPathExtension().lastPathComponent
                // A written transcript means a response came in
                tracker.mark(.code, .inbound, bytes: 0)
                return
            }
        }
    }
}

// MARK: - Login item via LaunchAgent

enum LoginItem {
    static let label = "com.claudeactivity.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        } else {
            try? fm.removeItem(at: plistURL)
        }
    }
}

// MARK: - About

enum About {
    static let repositoryURL = URL(string: "https://github.com/Promotos/ClaudeActivity")!

    static let summary =
        "Menu bar indicator that shows whether Claude is currently exchanging tokens — "
        + "both in the Claude Desktop app and in Claude Code."

    /// Apache-2.0 disclaimer, condensed to one sentence for the dialog.
    static let warranty =
        "Distributed on an \"AS IS\" basis, without warranties or conditions of any kind, "
        + "either express or implied. See the LICENSE file for details."

    /// "1.0" when marketing and build version match, otherwise "1.0 (7)".
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
    }

    /// The repository URL as a real hyperlink.
    /// An NSTextField only follows a `.link` attribute when it is both selectable
    /// and allowed to edit text attributes — with either flag missing the text
    /// merely looks like a link and does nothing when clicked.
    static func linkView() -> NSView {
        let attributed = NSAttributedString(
            string: repositoryURL.absoluteString,
            attributes: [
                .link: repositoryURL,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ])

        let field = NSTextField(labelWithAttributedString: attributed)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.sizeToFit()
        // NSAlert gives its accessory view a fixed width; keep the link from
        // being clipped on the right.
        field.frame = NSRect(x: 0, y: 0,
                             width: max(field.frame.width, 280),
                             height: field.frame.height)
        return field
    }

    /// Builds the About panel. Kept separate from showing it so the layout can
    /// be inspected without running a modal session.
    static func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ClaudeActivity \(version)"
        alert.informativeText = "\(summary)\n\n\(warranty)"
        alert.accessoryView = linkView()
        alert.addButton(withTitle: "OK")
        return alert
    }

    /// Shows the About panel. The app runs as an accessory, so it has to
    /// activate itself first — otherwise the alert opens behind the
    /// frontmost window.
    static func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        makeAlert().runModal()
    }
}

// MARK: - Icon rendering

/// All icons are template images: macOS tints them to match the menu bar.
/// Visibility is controlled purely through opacity — no color coding.
enum IconRenderer {
    private static var cache: [String: NSImage] = [:]

    static let rateFont = NSFont.monospacedDigitSystemFont(ofSize: Config.ratePointSize,
                                                           weight: .medium)
    /// Fixed width for the numbers so the icon does not jump around in the menu bar.
    static let textAreaWidth: CGFloat = ceil(
        NSAttributedString(string: "999 kB/s", attributes: [.font: rateFont]).size().width)
    static var totalWidth: CGFloat { Config.arrowsWidth + Config.textGap + textAreaWidth }

    /// Idle state: a sleeping "zzz".
    static func sleeping() -> NSImage {
        if let cached = cache["zzz"] { return cached }

        let image = NSImage(size: NSSize(width: totalWidth, height: Config.iconHeight))
        image.lockFocus()
        draw(symbol: "zzz", pointSize: Config.sleepPointSize, alpha: Config.sleepAlpha,
             in: NSRect(x: 0, y: 0, width: totalWidth, height: Config.iconHeight))
        image.unlockFocus()

        image.isTemplate = true
        cache["zzz"] = image
        return image
    }

    /// Activity: two stacked arrows with their respective rate beside them.
    /// The active direction is filled and blinks; the quiet one stays a faint outline.
    static func arrows(upActive: Bool, downActive: Bool, blinkOn: Bool,
                       upText: String, downText: String) -> NSImage {
        let key = "a-\(upActive)-\(downActive)-\(blinkOn)-\(upText)-\(downText)"
        if let cached = cache[key] { return cached }

        let w = Config.arrowsWidth
        let h = Config.iconHeight
        let image = NSImage(size: NSSize(width: totalWidth, height: h))

        let activeAlpha = blinkOn ? 1.0 : Config.blinkLowAlpha

        image.lockFocus()
        draw(symbol: upActive ? "arrowtriangle.up.fill" : "arrowtriangle.up",
             pointSize: Config.arrowPointSize,
             alpha: upActive ? activeAlpha : Config.idleArrowAlpha,
             in: NSRect(x: 0, y: h / 2, width: w, height: h / 2))
        draw(symbol: downActive ? "arrowtriangle.down.fill" : "arrowtriangle.down",
             pointSize: Config.arrowPointSize,
             alpha: downActive ? activeAlpha : Config.idleArrowAlpha,
             in: NSRect(x: 0, y: 0, width: w, height: h / 2))

        drawRate(upText, alpha: upActive ? 1.0 : Config.idleArrowAlpha,
                 in: NSRect(x: w + Config.textGap, y: h / 2,
                            width: textAreaWidth, height: h / 2))
        drawRate(downText, alpha: downActive ? 1.0 : Config.idleArrowAlpha,
                 in: NSRect(x: w + Config.textGap, y: 0,
                            width: textAreaWidth, height: h / 2))
        image.unlockFocus()

        image.isTemplate = true
        cache[key] = image

        // Bound the cache — the numbers produce a lot of variants
        if cache.count > 400 {
            cache = cache.filter { $0.key == "zzz" }
        }
        return image
    }

    /// Right-aligned small number inside one half of the icon.
    private static func drawRate(_ text: String, alpha: CGFloat, in rect: NSRect) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: rateFont,
            .foregroundColor: NSColor.black.withAlphaComponent(alpha)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let point = NSPoint(x: rect.maxX - size.width,
                            y: rect.minY + (rect.height - size.height) / 2)
        string.draw(at: point)
    }

    private static func draw(symbol: String, pointSize: CGFloat,
                             alpha: CGFloat, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.black]))
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        var size = symbolImage.size
        // If the symbol is wider than the icon (e.g. "zzz"), scale it down proportionally.
        if size.width > rect.width {
            let scale = rect.width / size.width
            size = NSSize(width: rect.width, height: size.height * scale)
        }
        let target = NSRect(x: rect.minX + (rect.width - size.width) / 2,
                            y: rect.minY + (rect.height - size.height) / 2,
                            width: size.width,
                            height: size.height)
        symbolImage.draw(in: target, from: .zero,
                         operation: .sourceOver, fraction: alpha)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = ActivityTracker()
    private let scanner = ProcessScanner()
    private var network: NetworkMonitor!
    private var transcripts: TranscriptMonitor!

    private var pollTimer: Timer?
    private var processTimer: Timer?
    private var pulseTimer: Timer?
    private var pulseOn = true

    private let worker = DispatchQueue(label: "claudeactivity.worker", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("ClaudeActivity started")
        statusItem = NSStatusBar.system.statusItem(withLength: IconRenderer.totalWidth + 6)
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        network = NetworkMonitor(scanner: scanner, tracker: tracker)
        transcripts = TranscriptMonitor(tracker: tracker)

        worker.async { [weak self] in self?.scanner.scan() }
        network.start()

        processTimer = Timer.scheduledTimer(withTimeInterval: Config.processScanInterval,
                                            repeats: true) { [weak self] _ in
            self?.worker.async { self?.scanner.scan() }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval,
                                         repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.worker.async {
                self.transcripts.check()
                DispatchQueue.main.async { self.render() }
            }
        }

        pulseTimer = Timer.scheduledTimer(withTimeInterval: Config.pulseInterval,
                                          repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.pulseOn.toggle()
            self.render()
        }

        render()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.write("ClaudeActivity is terminating")
        network.stop()
    }

    // MARK: Rendering

    private func render() {
        guard let button = statusItem.button else { return }

        let upActive = tracker.isActive(.outbound)
        let downActive = tracker.isActive(.inbound)

        if !upActive && !downActive {
            button.image = IconRenderer.sleeping()
            let newest = Source.allCases.compactMap { tracker.lastActivity($0) }.max()
            if let newest = newest {
                button.toolTip = "ClaudeActivity · last exchange "
                    + formatAge(Date().timeIntervalSince(newest)) + " ago"
            } else {
                button.toolTip = "ClaudeActivity is running · no exchange yet"
            }
            return
        }

        let upRate = Source.allCases.compactMap { tracker.currentRate($0, .outbound) }.reduce(0, +)
        let downRate = Source.allCases.compactMap { tracker.currentRate($0, .inbound) }.reduce(0, +)

        button.image = IconRenderer.arrows(upActive: upActive,
                                           downActive: downActive,
                                           blinkOn: pulseOn,
                                           upText: compactRate(upRate),
                                           downText: compactRate(downRate))

        var tips: [String] = []
        for direction in Direction.allCases {
            let sources = tracker.activeSources(direction)
            if !sources.isEmpty {
                let arrow = direction == .outbound ? "↑ sent" : "↓ received"
                tips.append("\(arrow): \(sources.map { $0.label }.joined(separator: ", "))")
            }
        }
        button.toolTip = tips.joined(separator: "\n")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let counts = scanner.counts

        for source in Source.allCases {
            let processes = source == .desktop ? counts.desktop : counts.code
            let title: String
            if processes == 0 {
                title = "○  \(source.label): not running"
            } else if tracker.isActive(source) {
                title = "●  \(source.label): active"
            } else if let last = tracker.lastActivity(source) {
                title = "○  \(source.label): last exchange \(formatAge(Date().timeIntervalSince(last))) ago"
            } else {
                title = "○  \(source.label): no exchange since app start"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)

            // Total volume since app start
            let totalUp = tracker.total(source, .outbound)
            let totalDown = tracker.total(source, .inbound)
            menu.addItem(detailItem(
                "      since start:  ↑ \(formatBytes(totalUp))   ↓ \(formatBytes(totalDown))"))
        }

        menu.addItem(.separator())

        var addedNote = false
        if !network.isRunning {
            let warn = NSMenuItem(
                title: "⚠︎ Network measurement inactive\(network.lastError.map { " (\($0))" } ?? "")",
                action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            addedNote = true
        }
        if !transcripts.rootExists {
            let warn = NSMenuItem(title: "⚠︎ ~/.claude/projects not found",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            addedNote = true
        }
        if let last = transcripts.lastFile {
            let item = NSMenuItem(title: "Last session: \(last)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addedNote = true
        }
        if addedNote { menu.addItem(.separator()) }

        let login = NSMenuItem(title: "Start at Login",
                               action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let about = NSMenuItem(title: "About ClaudeActivity",
                               action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ClaudeActivity",
                              action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Compact rate with unit for the menu bar:
    /// "0 B/s", "938 B/s", "1.2 kB/s", "47 kB/s", "1.8 MB/s".
    private func compactRate(_ bytes: Double) -> String {
        guard bytes >= 1 else { return "0 B/s" }
        if bytes < 1000 { return "\(Int(bytes)) B/s" }
        if bytes < 10_000 { return String(format: "%.1f kB/s", bytes / 1000) }
        if bytes < 1_000_000 { return String(format: "%.0f kB/s", bytes / 1000) }
        return String(format: "%.1f MB/s", bytes / 1_000_000)
    }

    /// Grey, smaller detail line without an action.
    private func detailItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                        weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        return item
    }

    /// "512 B", "18.4 KB", "1.2 MB" — localized through ByteCountFormatter.
    private func formatBytes(_ bytes: Double) -> String {
        guard bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// "12s", "3m", "2h 15m"
    private func formatAge(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    @objc private func showAbout(_ sender: Any?) {
        About.showPanel()
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Start

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
