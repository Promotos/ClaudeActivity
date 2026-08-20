//
//  ClaudeActivity
//  Copyright 2026 Promotos
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//

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
//
// The measured volume is also summed per day and kept for 30 days in
// ~/Library/Application Support/ClaudeActivity/usage-history.json, which feeds
// the mirrored bar chart in the menu (sent upwards, received downwards).
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
    /// How long the icon keeps the arrows after the last exchange before it
    /// falls back to "zzz". Clearly longer than activityHold, so the pauses
    /// inside a running conversation do not toggle the whole icon.
    static let sleepDelay: TimeInterval = 10
    /// Time constants of the rate smoothing in the menu bar. nettop samples jump
    /// around by a factor of ten between two seconds, so they are averaged — but
    /// asymmetrically: a burst shows up almost at once, and only the fall-off is
    /// drawn out, so the icon never claims traffic that stopped seconds ago.
    static let rateAttack: TimeInterval = 0.5
    static let rateRelease: TimeInterval = 1.5
    /// How often the number in the menu bar is re-worded — the icon itself is
    /// redrawn far more often for the blink.
    static let rateTextInterval: TimeInterval = 1.0
    /// How far *below* a unit boundary the rate has to fall before the label
    /// drops back down a step. Climbing happens right at the boundary, so the
    /// number never grows a fourth digit; only the way back is damped, which is
    /// what keeps a rate sitting at 1 kB/s from flipping the label every second.
    static let unitHysteresis: Double = 0.15

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

    // Usage history
    /// How many days the daily counters are kept — also the width of the chart.
    static let historyDays = 30
    /// How often the history is flushed to disk while the app runs.
    static let historySaveInterval: TimeInterval = 60

    // Chart geometry (the menu item showing the history)
    /// Minimum width of the chart — it grows to the width of the menu.
    static let chartWidth: CGFloat = 300
    static let chartHeight: CGFloat = 128
    /// Reserved above the bars for the legend. The hover bubble needs no room of
    /// its own — it is drawn over the chart.
    static let chartTopBand: CGFloat = 26
    /// Reserved below the bars for the first/last date label — wide enough to
    /// keep it clear of both the plot backdrop and the menu item below.
    static let chartBottomBand: CGFloat = 28
    /// How far the plot backdrop reaches past the bars on every side.
    static let chartPanelPadding: CGFloat = 5
    static let chartInset: CGFloat = 12
    /// Gap between two day columns.
    static let chartBarGap: CGFloat = 2
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

    /// One color per direction, used by the menu bar arrows, the menu and the
    /// chart alike: red leaves the machine, blue comes back.
    var color: NSColor {
        switch self {
        case .outbound: return .systemRed
        case .inbound: return .systemBlue
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

/// "512 B", "18.4 KB", "1.2 MB" — localized through ByteCountFormatter.
func formatBytes(_ bytes: Double) -> String {
    guard bytes > 0 else { return "0 B" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(bytes))
}

struct Key: Hashable {
    let source: Source
    let direction: Direction
}

// MARK: - Usage history (rolling window, persisted)

/// Day identifiers are plain "yyyy-MM-dd" strings in local time: they sort
/// chronologically, survive a locale change and read fine in the JSON file.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(for date: Date) -> String { formatter.string(from: date) }
    static func date(from key: String) -> Date? { formatter.date(from: key) }
}

/// The byte counters of a single day, split by source and direction.
struct DayUsage: Codable {
    let day: String
    var desktopOut: Double = 0
    var desktopIn: Double = 0
    var codeOut: Double = 0
    var codeIn: Double = 0

    var totalOut: Double { desktopOut + codeOut }
    var totalIn: Double { desktopIn + codeIn }
    var date: Date? { DayKey.date(from: day) }

    init(day: String) {
        self.day = day
    }

    /// Tolerant decoding: a file written by an older version may miss fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        desktopOut = try container.decodeIfPresent(Double.self, forKey: .desktopOut) ?? 0
        desktopIn = try container.decodeIfPresent(Double.self, forKey: .desktopIn) ?? 0
        codeOut = try container.decodeIfPresent(Double.self, forKey: .codeOut) ?? 0
        codeIn = try container.decodeIfPresent(Double.self, forKey: .codeIn) ?? 0
    }

    mutating func add(_ source: Source, _ direction: Direction, bytes: Double) {
        switch (source, direction) {
        case (.desktop, .outbound): desktopOut += bytes
        case (.desktop, .inbound): desktopIn += bytes
        case (.code, .outbound): codeOut += bytes
        case (.code, .inbound): codeIn += bytes
        }
    }

    /// Both directions of one source — used in the hover bubble.
    func total(_ source: Source) -> Double {
        source == .desktop ? desktopOut + desktopIn : codeOut + codeIn
    }
}

/// Keeps a rolling 30-day window of daily byte counters on disk, so the menu can
/// show a trend instead of only the totals since app start.
final class UsageHistory {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeActivity/usage-history.json")
    }

    private var days: [String: DayUsage] = [:]
    private var dirty = false
    private let lock = NSLock()

    init() {
        load()
    }

    /// Adds a measured delta to today's counters. Called from the nettop queue.
    func add(_ source: Source, _ direction: Direction, bytes: Double) {
        guard bytes > 0 else { return }
        let key = DayKey.key(for: Date())
        lock.lock()
        var entry = days[key] ?? DayUsage(day: key)
        entry.add(source, direction, bytes: bytes)
        days[key] = entry
        dirty = true
        lock.unlock()
    }

    /// The last `count` days, oldest first. Days without traffic — and every day
    /// before the app was ever installed — come back as zeroed entries, so the
    /// chart always has exactly `count` columns.
    func recent(_ count: Int = Config.historyDays) -> [DayUsage] {
        lock.lock()
        let snapshot = days
        lock.unlock()

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = DayKey.key(for: date)
            return snapshot[key] ?? DayUsage(day: key)
        }
    }

    /// Writes the window to disk — only when something changed since the last write.
    func save() {
        lock.lock()
        guard dirty else {
            lock.unlock()
            return
        }
        prune()
        let payload = days.values.sorted { $0.day < $1.day }
        dirty = false
        lock.unlock()

        let url = UsageHistory.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            Log.write("usage history could not be written: \(error.localizedDescription)")
            lock.lock()
            dirty = true
            lock.unlock()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: UsageHistory.fileURL) else { return }
        guard let entries = try? JSONDecoder().decode([DayUsage].self, from: data) else {
            Log.write("usage history is unreadable — starting a new one")
            return
        }
        lock.lock()
        days = Dictionary(entries.map { ($0.day, $0) }, uniquingKeysWith: { _, newer in newer })
        prune()
        lock.unlock()
        Log.write("usage history loaded (\(entries.count) days)")
    }

    /// Drops everything that has fallen out of the window. Call with the lock held.
    private func prune() {
        let calendar = Calendar.current
        guard let oldest = calendar.date(byAdding: .day, value: -(Config.historyDays - 1),
                                         to: calendar.startOfDay(for: Date())) else { return }
        let cutoff = DayKey.key(for: oldest)
        let before = days.count
        days = days.filter { $0.key >= cutoff }
        if days.count != before { dirty = true }
    }
}

// MARK: - Activity state

final class ActivityTracker {
    /// Same numbers as `totals`, but per day and kept across restarts.
    let history = UsageHistory()

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
        history.add(source, direction, bytes: bytes)
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
    ///
    /// The three blocks below run in this order for a reason:
    ///
    /// 1. Unambiguous Claude Code markers. Claude Code lives in
    ///    ~/Library/Application Support/Claude/claude-code/<version>/claude.app,
    ///    a path that also contains "claude.app" — so "claude-code" has to win
    ///    over the Desktop rule.
    /// 2. Claude Desktop. Its Electron helpers are spawned with names like
    ///    "Claude Helper --type=utility --utility-sub-type=node", which contain
    ///    both "node" and "claude". They must be settled here, before the loose
    ///    fallback below, or Desktop traffic ends up counted as Claude Code.
    /// 3. A loose fallback for Claude Code installed through npm outside the
    ///    known paths.
    static func classify(_ lower: String) -> Source? {
        if lower.contains("claudeactivity") { return nil }
        if lower.contains("claude usage") { return nil }   // third-party monitor app
        if lower.contains("nettop") || lower.hasPrefix("/bin/ps") { return nil }
        // The Squirrel updater downloads app releases, not tokens.
        if lower.contains("shipit") || lower.contains("squirrel") { return nil }

        if lower.contains("claude-code")
            || lower.contains(".claude/local")
            || lower.contains("claude/cli.js") {
            return .code
        }

        if lower.contains("/claude.app/") || lower.contains("claude helper") {
            return .desktop
        }

        if lower.contains("node") && lower.contains("claude") {
            return .code
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

    /// Copyright line, read from the bundle so it has a single source.
    /// Empty when running outside an app bundle.
    static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
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
        var paragraphs = [summary]
        if !copyright.isEmpty { paragraphs.append(copyright) }
        paragraphs.append(warranty)
        alert.informativeText = paragraphs.joined(separator: "\n\n")
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

/// The arrows carry the same colors as the chart — red for sent, blue for
/// received — so they cannot be template images any more. Everything that is not
/// an arrow is drawn in the label color of the menu bar's own appearance, which
/// is why the caller passes that appearance in.
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
        draw(symbol: "zzz", pointSize: Config.sleepPointSize,
             alpha: Config.sleepAlpha,
             in: NSRect(x: 0, y: 0, width: totalWidth, height: Config.iconHeight))
        image.unlockFocus()

        image.isTemplate = true
        cache["zzz"] = image
        return image
    }

    /// Activity: two stacked arrows with their respective rate beside them.
    /// The active direction is filled and blinks; the quiet one stays a faint outline.
    static func arrows(upActive: Bool, downActive: Bool, blinkOn: Bool,
                       upText: String, downText: String,
                       appearance: NSAppearance?) -> NSImage {
        let key = "a-\(upActive)-\(downActive)-\(blinkOn)-\(upText)-\(downText)"
            + "-\(appearance?.name.rawValue ?? "")"
        if let cached = cache[key] { return cached }

        let w = Config.arrowsWidth
        let h = Config.iconHeight
        let image = NSImage(size: NSSize(width: totalWidth, height: h))

        let activeAlpha = blinkOn ? 1.0 : Config.blinkLowAlpha

        image.lockFocus()
        withAppearance(appearance) {
            draw(symbol: upActive ? "arrowtriangle.up.fill" : "arrowtriangle.up",
                 pointSize: Config.arrowPointSize,
                 color: Direction.outbound.color,
                 alpha: upActive ? activeAlpha : Config.idleArrowAlpha,
                 in: NSRect(x: 0, y: h / 2, width: w, height: h / 2))
            draw(symbol: downActive ? "arrowtriangle.down.fill" : "arrowtriangle.down",
                 pointSize: Config.arrowPointSize,
                 color: Direction.inbound.color,
                 alpha: downActive ? activeAlpha : Config.idleArrowAlpha,
                 in: NSRect(x: 0, y: 0, width: w, height: h / 2))

            drawRate(upText, alpha: upActive ? 1.0 : Config.idleArrowAlpha,
                     in: NSRect(x: w + Config.textGap, y: h / 2,
                                width: textAreaWidth, height: h / 2))
            drawRate(downText, alpha: downActive ? 1.0 : Config.idleArrowAlpha,
                     in: NSRect(x: w + Config.textGap, y: 0,
                                width: textAreaWidth, height: h / 2))
        }
        image.unlockFocus()

        image.isTemplate = false
        cache[key] = image

        // Bound the cache — the numbers produce a lot of variants
        if cache.count > 400 {
            cache = cache.filter { $0.key == "zzz" }
        }
        return image
    }

    /// Draws with the menu bar's appearance in effect, so that labelColor comes
    /// out light on a dark menu bar and dark on a light one.
    private static func withAppearance(_ appearance: NSAppearance?, _ body: () -> Void) {
        guard let appearance = appearance else { return body() }
        appearance.performAsCurrentDrawingAppearance(body)
    }

    /// Right-aligned small number inside one half of the icon.
    private static func drawRate(_ text: String, alpha: CGFloat, in rect: NSRect) {
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: rateFont,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let point = NSPoint(x: rect.maxX - size.width,
                            y: rect.minY + (rect.height - size.height) / 2)
        string.draw(at: point)
    }

    private static func draw(symbol: String, pointSize: CGFloat,
                             color: NSColor = .black,
                             alpha: CGFloat, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
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

// MARK: - Chart tooltip

/// The hover detail of the chart, in a borderless window of its own.
///
/// A menu clips every item view to its own frame, so a bubble drawn inside the
/// chart would have to cover the very bars it describes. A separate window one
/// level above the menu can float above them instead.
final class UsageTooltip {
    static let shared = UsageTooltip()

    static let padding = NSSize(width: 9, height: 6)
    static let pointerSize = NSSize(width: 12, height: 6)
    static let cornerRadius: CGFloat = 7
    private static let maxTextWidth: CGFloat = 280

    private let content = UsageTooltipView()
    private let window: NSWindow

    private init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless,
                          backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        // Menus live at .popUpMenu; one level up puts the bubble above them.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle,
                                     .fullScreenAuxiliary]
        window.contentView = content
    }

    /// Shows the bubble with its pointer touching `anchor` (in screen coordinates).
    func show(_ text: NSAttributedString, anchor: NSPoint, appearance: NSAppearance?) {
        let textSize = text.boundingRect(
            with: NSSize(width: UsageTooltip.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).size
        let size = NSSize(
            width: ceil(textSize.width) + 2 * UsageTooltip.padding.width,
            height: ceil(textSize.height) + 2 * UsageTooltip.padding.height
                + UsageTooltip.pointerSize.height)

        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }

        window.appearance = appearance
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        content.text = text
        content.pointerX = anchor.x - origin.x
        content.needsDisplay = true
        window.orderFrontRegardless()
        window.invalidateShadow()
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// Draws the bubble itself: rounded rect with a pointer at the bottom edge.
final class UsageTooltipView: NSView {
    var text = NSAttributedString()
    /// Where the pointer sits, measured from the left edge of the view.
    var pointerX: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let pointer = UsageTooltip.pointerSize
        let body = NSRect(x: 0, y: pointer.height,
                          width: bounds.width, height: bounds.height - pointer.height)

        // Body and pointer are one path, so a single fill leaves no seam and the
        // window shadow follows the whole outline.
        let path = NSBezierPath(roundedRect: body,
                                xRadius: UsageTooltip.cornerRadius,
                                yRadius: UsageTooltip.cornerRadius)
        let tipX = min(max(pointerX, body.minX + UsageTooltip.cornerRadius + pointer.width / 2),
                       body.maxX - UsageTooltip.cornerRadius - pointer.width / 2)
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: tipX - pointer.width / 2, y: body.minY + 1))
        tip.line(to: NSPoint(x: tipX, y: 0))
        tip.line(to: NSPoint(x: tipX + pointer.width / 2, y: body.minY + 1))
        tip.close()
        path.append(tip)
        path.windingRule = .nonZero

        NSColor.controlBackgroundColor.setFill()
        path.fill()

        text.draw(with: body.insetBy(dx: UsageTooltip.padding.width,
                                     dy: UsageTooltip.padding.height),
                  options: [.usesLineFragmentOrigin])
    }
}

// MARK: - Usage history chart

/// Mirrored bar chart for the menu: one column per day, sent growing upwards and
/// received growing downwards from a shared baseline. Both halves use the same
/// scale, so the two directions stay comparable.
///
/// Hovering a column dims the rest and replaces the legend with a bubble that
/// details that day. The bubble is drawn inside the view — a real tooltip or a
/// popover would be swallowed by the menu's own event tracking.
final class UsageChartView: NSView {
    private let days: [DayUsage]
    /// Largest single-direction value in the window.
    private let peak: Double
    /// `peak` rounded up to a readable number — the end of both half axes.
    private let scaleMax: Double
    /// Room the axis labels need on the left.
    private let scaleWidth: CGFloat
    private var hoverIndex: Int?

    private static let outColor = Direction.outbound.color
    private static let inColor = Direction.inbound.color

    /// Backdrop of the plot area and the hovered column. Both are mixed by hand
    /// per appearance: the semantic greys (quaternaryLabelColor and friends) are
    /// nearly invisible against the dark menu background.
    private static let panelColor = shade(light: 0.05, dark: 0.08)
    private static let hoverColor = shade(light: 0.11, dark: 0.16)
    private static let gridColor = shade(light: 0.10, dark: 0.14)

    private static func shade(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: dark)
                : NSColor(white: 0, alpha: light)
        }
    }

    static let scaleFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

    /// The three labels of the axis, top to bottom.
    private static func axisLabels(_ max: Double) -> [String] {
        max > 0 ? [formatBytes(max), "0", formatBytes(max)] : ["0"]
    }

    /// Rounds up to a readable multiple of a power of ten, so the axis ends on a
    /// number worth reading instead of on the busiest day's exact volume. The
    /// ladder is fine enough that little amplitude is given away.
    private static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0] where value <= step * magnitude {
            return step * magnitude
        }
        return 10 * magnitude
    }

    private static let axisDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private static let bubbleDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    init(days: [DayUsage]) {
        self.days = days
        let peak = days.map { max($0.totalOut, $0.totalIn) }.max() ?? 0
        self.peak = peak
        self.scaleMax = UsageChartView.niceCeiling(peak)
        self.scaleWidth = UsageChartView.axisLabels(scaleMax).map {
            NSAttributedString(string: $0, attributes: [.font: UsageChartView.scaleFont]).size().width
        }.max().map { ceil($0) + 6 } ?? 0
        super.init(frame: NSRect(x: 0, y: 0, width: Config.chartWidth, height: Config.chartHeight))
        // The other menu items are wider than the chart's own minimum width, and
        // the menu is only as wide as its widest item — so the chart has to grow
        // into whatever width the menu ends up with.
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("UsageChartView is created in code only")
    }

    // MARK: Geometry

    /// The area the bars live in — everything above and below is reserved.
    private var plotRect: NSRect {
        NSRect(x: Config.chartInset + scaleWidth,
               y: Config.chartBottomBand,
               width: bounds.width - 2 * Config.chartInset - scaleWidth,
               height: bounds.height - Config.chartBottomBand - Config.chartTopBand)
    }

    private var columnWidth: CGFloat {
        days.isEmpty ? 0 : plotRect.width / CGFloat(days.count)
    }

    private func columnRect(_ index: Int) -> NSRect {
        NSRect(x: plotRect.minX + CGFloat(index) * columnWidth,
               y: plotRect.minY,
               width: columnWidth,
               height: plotRect.height)
    }

    /// AppKit resizes an item view with a flexible width to the menu width, but
    /// only once the menu has laid itself out — and not at all in every macOS
    /// version. Matching the enclosing view before drawing covers both cases.
    private func fitToEnclosingMenu() {
        guard let width = superview?.bounds.width, width > frame.width + 0.5 else { return }
        setFrameSize(NSSize(width: width, height: frame.height))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        fitToEnclosingMenu()
    }

    override func viewWillDraw() {
        fitToEnclosingMenu()
        super.viewWillDraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Hover

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The menu window does not forward mouse-moved events on its own.
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self,
                                       userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard columnWidth > 0, point.x >= plotRect.minX, point.x < plotRect.maxX else {
            setHover(nil)
            return
        }
        let index = Int((point.x - plotRect.minX) / columnWidth)
        setHover(min(max(index, 0), days.count - 1))
    }

    private func setHover(_ index: Int?) {
        guard hoverIndex != index else { return }
        hoverIndex = index
        needsDisplay = true
        updateTooltip()
    }

    /// The bubble hangs above the whole chart item, so it never covers a bar.
    private func updateTooltip() {
        guard let index = hoverIndex, peak > 0, let window = window else {
            UsageTooltip.shared.hide()
            return
        }
        let top = NSPoint(x: columnRect(index).midX, y: bounds.maxY)
        let anchor = window.convertPoint(toScreen: convert(top, to: nil))
        UsageTooltip.shared.show(tooltipText(for: days[index]),
                                 anchor: anchor,
                                 appearance: effectiveAppearance)
    }

    /// Called when the menu closes — the view is torn down without a mouseExited.
    func hideTooltip() {
        hoverIndex = nil
        UsageTooltip.shared.hide()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { hideTooltip() }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect

        UsageChartView.panelColor.setFill()
        NSBezierPath(roundedRect: plot.insetBy(dx: -Config.chartPanelPadding,
                                               dy: -Config.chartPanelPadding),
                     xRadius: 6, yRadius: 6).fill()

        guard peak > 0 else {
            drawEmptyState(in: plot)
            drawLegend()
            return
        }

        drawBars(in: plot)
        drawBaseline(in: plot)
        drawScale(in: plot)
        drawAxisLabels(in: plot)

        drawLegend()
    }

    /// Values are measured against the axis maximum, not against the peak itself.
    private func drawBars(in plot: NSRect) {
        let half = plot.height / 2 - 1
        let barWidth = max(2, columnWidth - Config.chartBarGap)

        for (index, day) in days.enumerated() {
            let column = columnRect(index)
            let highlighted = hoverIndex == index

            if highlighted {
                UsageChartView.hoverColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: column.minX, y: plot.minY - 4,
                                                 width: column.width, height: plot.height + 8),
                             xRadius: 3, yRadius: 3).fill()
            }

            let alpha: CGFloat = (hoverIndex == nil || highlighted) ? 1.0 : 0.3
            drawBar(day.totalOut, x: column.midX - barWidth / 2, width: barWidth,
                    baseline: plot.midY, half: half, upwards: true,
                    color: UsageChartView.outColor.withAlphaComponent(alpha))
            drawBar(day.totalIn, x: column.midX - barWidth / 2, width: barWidth,
                    baseline: plot.midY, half: half, upwards: false,
                    color: UsageChartView.inColor.withAlphaComponent(alpha))
        }
    }

    /// A day with traffic always gets a visible stub, however small its share.
    private func drawBar(_ value: Double, x: CGFloat, width: CGFloat, baseline: CGFloat,
                         half: CGFloat, upwards: Bool, color: NSColor) {
        guard value > 0 else { return }
        let height = max(1.5, CGFloat(value / scaleMax) * half)
        let rect = NSRect(x: x, y: upwards ? baseline : baseline - height,
                          width: width, height: height)
        let radius = min(1.5, width / 2)
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// The value axis: the rounded maximum at either end, zero at the baseline.
    /// Both halves share it, so a bar up and a bar down are directly comparable.
    private func drawScale(in plot: NSRect) {
        guard scaleMax > 0 else { return }
        let labels = UsageChartView.axisLabels(scaleMax)
        let levels = [plot.maxY, plot.midY, plot.minY]

        for (text, y) in zip(labels, levels) {
            let string = NSAttributedString(
                string: text,
                attributes: [.font: UsageChartView.scaleFont,
                             .foregroundColor: NSColor.secondaryLabelColor])
            let size = string.size()
            string.draw(at: NSPoint(x: plot.minX - Config.chartPanelPadding - 3 - size.width,
                                    y: y - size.height / 2))
        }

        // Hairlines at ±max, so the ends of the axis are visible in the plot too.
        UsageChartView.gridColor.setFill()
        for y in [plot.maxY, plot.minY] {
            NSRect(x: plot.minX, y: y - 0.5, width: plot.width, height: 1).fill()
        }
    }

    private func drawBaseline(in plot: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: plot.minX, y: plot.midY - 0.5, width: plot.width, height: 1).fill()
    }

    /// Only the ends of the window are labelled — 30 dates would not fit.
    private func drawAxisLabels(in plot: NSRect) {
        guard let first = days.first?.date, let last = days.last?.date else { return }
        let left = caption(UsageChartView.axisDate.string(from: first))
        let right = caption(UsageChartView.axisDate.string(from: last))
        // Centred between the bottom edge of the plot backdrop and the view edge,
        // so the date neither touches the chart nor the item below it.
        let y = (Config.chartBottomBand - Config.chartPanelPadding - left.size().height) / 2
        left.draw(at: NSPoint(x: plot.minX, y: y))
        right.draw(at: NSPoint(x: plot.maxX - right.size().width, y: y))
    }

    /// Which color means what, plus the scale of the chart.
    private func drawLegend() {
        let legend = NSMutableAttributedString()
        legend.append(NSAttributedString(string: "↑ sent",
                                         attributes: labelAttributes(UsageChartView.outColor)))
        legend.append(NSAttributedString(string: "   ↓ received",
                                         attributes: labelAttributes(UsageChartView.inColor)))
        // Sits just above the plot backdrop, mirroring the date row below it.
        let y = plotRect.maxY + Config.chartPanelPadding + 3
        legend.draw(at: NSPoint(x: Config.chartInset, y: y))

        if peak > 0 {
            let busiest = caption("busiest day \(formatBytes(peak))")
            busiest.draw(at: NSPoint(x: bounds.width - Config.chartInset - busiest.size().width, y: y))
        }
    }

    private func drawEmptyState(in plot: NSRect) {
        let text = caption("No traffic recorded yet")
        text.draw(at: NSPoint(x: plot.midX - text.size().width / 2,
                              y: plot.midY - text.size().height / 2))
    }

    /// The hover detail: date, both directions, and the split by source.
    private func tooltipText(for day: DayUsage) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let date = day.date {
            text.append(NSAttributedString(
                string: UsageChartView.bubbleDate.string(from: date) + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                             .foregroundColor: NSColor.labelColor]))
        }
        text.append(NSAttributedString(string: "↑ \(formatBytes(day.totalOut))",
                                       attributes: labelAttributes(UsageChartView.outColor)))
        text.append(NSAttributedString(string: "   ↓ \(formatBytes(day.totalIn))\n",
                                       attributes: labelAttributes(UsageChartView.inColor)))
        text.append(NSAttributedString(
            string: "\(Source.desktop.label) \(formatBytes(day.total(.desktop)))"
                + "  ·  \(Source.code.label) \(formatBytes(day.total(.code)))",
            attributes: [.font: NSFont.systemFont(ofSize: 9.5),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        return text
    }

    private func labelAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
         .foregroundColor: color]
    }

    private func caption(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string,
                           attributes: [.font: NSFont.systemFont(ofSize: 9.5),
                                        .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: - Rate display

/// Turns the raw nettop samples into the text beside an arrow in the menu bar.
///
/// Three things happen here, all of them against flicker: the value is smoothed
/// over time, the wording is renewed at most once a second (the icon itself is
/// redrawn every 0.4 s for the blink), and the unit is held until the rate is
/// clearly past the boundary.
final class RateDisplay {
    private var smoothed: [Direction: (value: Double, at: Date)] = [:]
    private var label: [Direction: (text: String, at: Date)] = [:]
    private var unit: [Direction: Int] = [:]

    /// The text to show for `raw`, the sum of the current samples of a direction.
    func text(_ direction: Direction, raw: Double, now: Date = Date()) -> String {
        let value = smooth(direction, raw: raw, now: now)
        if let current = label[direction],
           now.timeIntervalSince(current.at) < Config.rateTextInterval {
            return current.text
        }
        let text = format(value, for: direction)
        label[direction] = (text, now)
        return text
    }

    /// Exponential smoothing whose weight comes from the time since the last
    /// call, so it does not matter that the caller runs on two different timers.
    private func smooth(_ direction: Direction, raw: Double, now: Date) -> Double {
        guard let previous = smoothed[direction] else {
            smoothed[direction] = (raw, now)
            return raw
        }
        let elapsed = max(0, now.timeIntervalSince(previous.at))
        let constant = raw > previous.value ? Config.rateAttack : Config.rateRelease
        let weight = 1 - exp(-elapsed / constant)
        let value = previous.value + (raw - previous.value) * weight
        smoothed[direction] = (value, now)
        return value
    }

    /// "0 B/s", "938 B/s", "1.2 kB/s", "47 kB/s", "1.8 MB/s" — with the step
    /// held until the rate is a good bit past the boundary. Without that, a rate
    /// hovering around 1 kB/s rewrites the label, and with it the width of the
    /// number, on every single sample.
    private func format(_ bytes: Double, for direction: Direction) -> String {
        // Boundaries between "123 B/s", "1.2 kB/s", "47 kB/s" and "1.8 MB/s".
        let boundaries: [Double] = [1_000, 10_000, 1_000_000]
        var step = min(unit[direction] ?? 0, boundaries.count)

        while step < boundaries.count, bytes >= boundaries[step] {
            step += 1
        }
        while step > 0, bytes < boundaries[step - 1] * (1 - Config.unitHysteresis) {
            step -= 1
        }
        unit[direction] = step

        switch step {
        case 0: return "\(Int(bytes.rounded())) B/s"
        case 1: return String(format: "%.1f kB/s", bytes / 1_000)
        case 2: return String(format: "%.0f kB/s", bytes / 1_000)
        default: return String(format: "%.1f MB/s", bytes / 1_000_000)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = ActivityTracker()
    private let scanner = ProcessScanner()
    private var network: NetworkMonitor!
    private var transcripts: TranscriptMonitor!

    /// Kept only to take the hover bubble down when the menu closes.
    private weak var chartView: UsageChartView?

    /// Smoothing and wording of the two rates in the menu bar.
    private let rates = RateDisplay()

    private var pollTimer: Timer?
    private var processTimer: Timer?
    private var historyTimer: Timer?
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

        historyTimer = Timer.scheduledTimer(withTimeInterval: Config.historySaveInterval,
                                            repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.worker.async { self.tracker.history.save() }
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
        tracker.history.save()
    }

    // MARK: Rendering

    private func render() {
        guard let button = statusItem.button else { return }
        let now = Date()

        let upActive = tracker.isActive(.outbound)
        let downActive = tracker.isActive(.inbound)

        // Fed on every render, also while nothing is "active", so the smoothing
        // decays instead of freezing on the last value of a burst.
        let upText = rates.text(.outbound, raw: rawRate(.outbound), now: now)
        let downText = rates.text(.inbound, raw: rawRate(.inbound), now: now)

        let newest = Source.allCases.compactMap { tracker.lastActivity($0) }.max()
        let idle = newest.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        // Between activityHold and sleepDelay the arrows stay, only dimmed — that
        // is what keeps the icon from flickering between "zzz" and the rates
        // during the short pauses of a streaming response.
        if idle > Config.sleepDelay {
            button.image = IconRenderer.sleeping()
            if let newest = newest {
                button.toolTip = "ClaudeActivity · last exchange "
                    + formatAge(now.timeIntervalSince(newest)) + " ago"
            } else {
                button.toolTip = "ClaudeActivity is running · no exchange yet"
            }
            return
        }

        button.image = IconRenderer.arrows(upActive: upActive,
                                           downActive: downActive,
                                           blinkOn: pulseOn,
                                           upText: upText,
                                           downText: downText,
                                           appearance: button.effectiveAppearance)

        var tips: [String] = []
        for direction in Direction.allCases {
            let sources = tracker.activeSources(direction)
            if !sources.isEmpty {
                let arrow = direction == .outbound ? "↑ sent" : "↓ received"
                tips.append("\(arrow): \(sources.map { $0.label }.joined(separator: ", "))")
            }
        }
        if tips.isEmpty, let newest = newest {
            tips.append("ClaudeActivity · last exchange "
                + formatAge(now.timeIntervalSince(newest)) + " ago")
        }
        button.toolTip = tips.joined(separator: "\n")
    }

    /// Sum of the current samples of all sources in one direction.
    private func rawRate(_ direction: Direction) -> Double {
        Source.allCases.compactMap { tracker.currentRate($0, direction) }.reduce(0, +)
    }

    // MARK: Menu

    func menuDidClose(_ menu: NSMenu) {
        chartView?.hideTooltip()
    }

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
            menu.addItem(totalsItem(up: totalUp, down: totalDown))
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("Usage history · last \(Config.historyDays) days"))
        let chart = NSMenuItem()
        let chartView = UsageChartView(days: tracker.history.recent())
        chart.view = chartView
        self.chartView = chartView
        menu.addItem(chart)

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

    /// Grey detail line with the volume since app start; the arrows carry the
    /// same colors as the chart.
    private func totalsItem(up: Double, down: Double) -> NSMenuItem {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
        let text = NSMutableAttributedString()
        func append(_ string: String, _ color: NSColor) {
            text.append(NSAttributedString(string: string,
                                           attributes: [.font: font, .foregroundColor: color]))
        }
        append("      since start:  ", .secondaryLabelColor)
        append("\u{2191} ", Direction.outbound.color)
        append("\(formatBytes(up))   ", .secondaryLabelColor)
        append("\u{2193} ", Direction.inbound.color)
        append(formatBytes(down), .secondaryLabelColor)

        let item = NSMenuItem(title: text.string, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = text
        return item
    }

    /// Small grey caption introducing a section of the menu.
    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
        return item
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
