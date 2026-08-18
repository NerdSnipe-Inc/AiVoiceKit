// Sources/AiVoiceKit/macOS/Command/TerminalService.swift
// Ported from FluidVoice — stripped of FluidVoice-specific imports.
#if os(macOS)
import Foundation

/// Simple terminal command execution service.
/// All responses are JSON-parsable for easy AI processing.
public final class TerminalService: @unchecked Sendable {
    // MARK: - Types

    public struct CommandResult: Codable, Sendable {
        public let success: Bool
        public let command: String
        public let output: String
        public let error: String?
        public let exitCode: Int32
        public let executionTimeMs: Int
    }

    // MARK: - Tool Definition (OpenAI function-calling format)

    public static var toolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "execute_terminal_command",
                "description": """
                Execute a terminal/shell command on the user's macOS computer.
                Use this for file operations (ls, cat, mkdir, rm), git commands, brew, npm, python, or any CLI tool.

                IMPORTANT: Follow the agentic workflow:
                1. ALWAYS check prerequisites first (file exists, command available)
                2. Execute the main action
                3. Verify the result

                Returns JSON with: success (bool), output (stdout), error (stderr), exitCode, purpose.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute (e.g., 'ls -la', 'git status', 'rm file.txt')",
                        ],
                        "workingDirectory": [
                            "type": "string",
                            "description": "Optional working directory path. Defaults to user home directory.",
                        ],
                        "purpose": [
                            "type": "string",
                            "description": "Brief description of why this command is being run.",
                        ],
                    ] as [String: Any],
                    "required": ["command", "purpose"],
                ],
            ] as [String: Any],
        ]
    }

    // MARK: - Init

    public init() {}

    // MARK: - Execution

    /// Execute a shell command and return a structured result.
    public func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async -> CommandResult {
        let startTime = Date()

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        if let dir = workingDirectory, !dir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        // Inherit user environment; prepend common tool paths
        var environment = ProcessInfo.processInfo.environment
        if let path = environment["PATH"] {
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(path)"
        }
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            timeoutTask.cancel()

            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let errorText = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            return CommandResult(
                success: process.terminationStatus == 0,
                command: command,
                output: output,
                error: errorText?.isEmpty == true ? nil : errorText,
                exitCode: process.terminationStatus,
                executionTimeMs: ms
            )
        } catch {
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            return CommandResult(
                success: false,
                command: command,
                output: "",
                error: "Failed to launch process: \(error.localizedDescription)",
                exitCode: -1,
                executionTimeMs: ms
            )
        }
    }

    /// Encode a `CommandResult` to a JSON string for AI processing.
    public func resultToJSON(_ result: CommandResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        let fallback: [String: Any] = [
            "success": result.success,
            "output": result.output,
            "exitCode": Int(result.exitCode),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        return #"{"success":false,"output":"<json-serialization-failed>","exitCode":-1}"#
    }
}
#endif
