// Sources/AiVoiceKit/Shared/DebugLogger.swift
// Ported from FluidVoice/Sources/Fluid/Services/DebugLogger.swift
// Changes: public access, log category default changed to "AiVoiceKit",
//          analytics references removed.
import Combine
import Foundation

public class DebugLogger: ObservableObject, @unchecked Sendable {
    public static let shared = DebugLogger()

    @Published public var logs: [LogEntry] = []
    private let maxLogs = 1000
    private let queue = DispatchQueue(label: "com.nerdsnipe.alric.voice.debug.logger", qos: .utility)

    // IMPORTANT: Cached setting to avoid circular dependency with VoiceSettingsStore.
    // During VoiceSettingsStore.init(), if an error is logged, accessing VoiceSettingsStore.shared
    // would cause a recursive dispatch_once deadlock. Use a cached value instead.
    private var _loggingEnabledCache: Bool?
    private var loggingEnabled: Bool {
        if let cached = _loggingEnabledCache {
            return cached
        }
        let defaults = UserDefaults(suiteName: "com.nerdsnipe.alric.voice") ?? .standard
        let enabled: Bool
        if defaults.object(forKey: "enableDebugLogs") == nil {
            enabled = false
        } else {
            enabled = defaults.bool(forKey: "enableDebugLogs")
        }
        self._loggingEnabledCache = enabled
        return enabled
    }

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    public struct LogEntry: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let level: LogLevel
        public let message: String
        public let source: String
        public let formattedTimestamp: String

        public init(timestamp: Date, level: LogLevel, message: String, source: String, formattedTimestamp: String) {
            self.timestamp = timestamp
            self.level = level
            self.message = message
            self.source = source
            self.formattedTimestamp = formattedTimestamp
        }
    }

    public enum LogLevel: String, CaseIterable, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private init() {}

    /// Refresh the cached logging setting (call after VoiceSettingsStore is fully initialized).
    public func refreshLoggingEnabled() {
        let defaults = UserDefaults(suiteName: "com.nerdsnipe.alric.voice") ?? .standard
        if defaults.object(forKey: "enableDebugLogs") == nil {
            self._loggingEnabledCache = false
        } else {
            self._loggingEnabledCache = defaults.bool(forKey: "enableDebugLogs")
        }
    }

    public func log(_ message: String, level: LogLevel = .info, source: String = "AiVoiceKit") {
        let loggingEnabled = self.loggingEnabled

        self.queue.async {
            let timestamp = Date()
            let timestampString = Self.logFormatter.string(from: timestamp)

            let formattedLine = self.formatLogLine(timestamp: timestampString, level: level, source: source, message: message)

            // Always persist diagnostics so issues can be debugged even if UI debug mode is off.
            FileLogger.shared.append(line: formattedLine)
            print(formattedLine)

            guard loggingEnabled else { return }

            let entry = LogEntry(
                timestamp: timestamp,
                level: level,
                message: message,
                source: source,
                formattedTimestamp: timestampString
            )

            DispatchQueue.main.async {
                self.logs.append(entry)

                if self.logs.count > self.maxLogs + 100 {
                    let excess = self.logs.count - self.maxLogs
                    if excess > 0 {
                        self.logs.removeFirst(excess)
                    }
                }
            }
        }
    }

    public func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }

    public func exportLogs() -> String {
        return self.logs.map { entry in
            self.formatLogEntry(entry)
        }.joined(separator: "\n")
    }

    private func formatLogEntry(_ entry: LogEntry) -> String {
        self.formatLogLine(timestamp: entry.formattedTimestamp, level: entry.level, source: entry.source, message: entry.message)
    }

    private func formatLogLine(timestamp: String, level: LogLevel, source: String, message: String) -> String {
        "[\(timestamp)] [\(level.rawValue)] [\(source)] \(message)"
    }
}

// MARK: - Convenience wrappers

extension DebugLogger {
    public func info(_ message: String, source: String = "AiVoiceKit") {
        self.log(message, level: .info, source: source)
    }

    public func benchmark(_ marker: String, message: String, source: String = "Benchmark") {
        let now = ProcessInfo.processInfo.systemUptime
        self.info("\(marker) t=\(String(format: "%.6f", now)) \(message)", source: source)
    }

    public func warning(_ message: String, source: String = "AiVoiceKit") {
        self.log(message, level: .warning, source: source)
    }

    public func error(_ message: String, source: String = "AiVoiceKit") {
        self.log(message, level: .error, source: source)
    }

    public func debug(_ message: String, source: String = "AiVoiceKit") {
        self.log(message, level: .debug, source: source)
    }
}
