// Sources/AiVoiceKit/macOS/Command/CommandModeService.swift
// Ported from FluidVoice — FluidVoice-specific deps removed.
// LLM call is delegated to onCommandReceived supplied by the host app.
#if os(macOS)
import Combine
import Foundation

/// Manages the command-mode conversation state and agentic loop.
///
/// The host app supplies an `onCommandReceived` closure at init.  When a
/// recognised "Alric …" utterance arrives, `CommandModeRouter` extracts the
/// command text and calls that closure.  `CommandModeService` coordinates the
/// subsequent agentic state — conversation history, processing flag, pending
/// confirmation, and step tracking — so the host UI can bind to it directly.
@MainActor
public final class CommandModeService: ObservableObject {
    // MARK: - Published state

    @Published public var conversationHistory: [Message] = []
    @Published public var isProcessing = false
    @Published public var pendingCommand: PendingCommand? = nil
    @Published public var currentStep: AgentStep? = nil

    // MARK: - Types

    public enum AgentStep: Equatable {
        case thinking(String)
        case checking(String)
        case executing(String)
        case verifying(String)
        case completed(Bool)
    }

    public struct Message: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let role: Role
        public let content: String
        public let toolCall: ToolCall?
        public let stepType: StepType
        public let timestamp: Date

        public enum Role: Equatable, Sendable {
            case user, assistant, tool
        }

        public enum StepType: Equatable, Sendable {
            case normal, thinking, checking, executing, verifying, success, failure
        }

        public struct ToolCall: Equatable, Sendable {
            public let id: String
            public let command: String
            public let workingDirectory: String?
            public let purpose: String?
        }

        public init(
            role: Role,
            content: String,
            toolCall: ToolCall? = nil,
            stepType: StepType = .normal
        ) {
            self.role = role
            self.content = content
            self.toolCall = toolCall
            self.stepType = stepType
            self.timestamp = Date()
        }
    }

    public struct PendingCommand: Sendable {
        public let id: String
        public let command: String
        public let workingDirectory: String?
        public let purpose: String?
    }

    // MARK: - Dependencies

    private nonisolated(unsafe) let terminalService = TerminalService()
    /// Called when a complete command string is ready for the AI to act on.
    public var onCommandReceived: ((String) async -> Void)?

    // MARK: - Private state

    private var currentTurnCount = 0
    private let maxTurns = 20

    // MARK: - Init

    public init(onCommandReceived: ((String) async -> Void)? = nil) {
        self.onCommandReceived = onCommandReceived
    }

    // MARK: - Public API

    /// Submit a voice/text command for processing.
    public func processUserCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isProcessing = true
        currentTurnCount = 0
        conversationHistory.append(Message(role: .user, content: text))

        // Delegate to host-app AI handler
        if let handler = onCommandReceived {
            currentStep = .thinking("Analyzing…")
            await handler(text)
        }

        isProcessing = false
        currentStep = .completed(true)
    }

    /// Execute a pending command after user confirmation.
    public func confirmAndExecute() async {
        guard let pending = pendingCommand else { return }
        pendingCommand = nil
        isProcessing = true

        await executeCommand(pending.command, workingDirectory: pending.workingDirectory, callId: pending.id)
    }

    /// Cancel a pending destructive command.
    public func cancelPendingCommand() {
        pendingCommand = nil
        conversationHistory.append(Message(
            role: .assistant,
            content: "Command cancelled.",
            stepType: .failure
        ))
        isProcessing = false
        currentStep = nil
    }

    /// Clear conversation history.
    public func clearHistory() {
        conversationHistory.removeAll()
        pendingCommand = nil
        currentTurnCount = 0
    }

    // MARK: - Terminal execution (used when host app delegates back)

    /// Execute a shell command directly (e.g. after host-app tool-call dispatch).
    public func executeCommand(
        _ command: String,
        workingDirectory: String?,
        callId: String,
        purpose: String? = nil
    ) async {
        currentStep = .executing(command)

        let result = await terminalService.execute(
            command: command,
            workingDirectory: workingDirectory
        )

        let resultJSON = terminalService.resultToJSON(result)
        let stepType: Message.StepType = result.success ? .success : .failure

        conversationHistory.append(Message(
            role: .tool,
            content: resultJSON,
            stepType: stepType
        ))

        isProcessing = false
        currentStep = .completed(result.success)
    }

    // MARK: - Destructive-command detection

    public func isDestructiveCommand(_ command: String) -> Bool {
        let cmd = command.lowercased()
        let destructivePrefixes = [
            "rm ", "rm\t", "rmdir ", "rm -",
            "mv ", "mv\t",
            "sudo ",
            "kill ", "pkill ", "killall ",
            "chmod ", "chown ", "chgrp ",
            "dd ",
            "mkfs", "format",
            "> ",
            "truncate ",
            "shred ",
        ]
        if destructivePrefixes.contains(where: { cmd.hasPrefix($0) }) { return true }

        let destructivePatterns = [
            "| rm ", "| sudo ", "| dd ",
            "; rm ", "; sudo ",
            "&& rm ", "&& sudo ",
            "xargs rm", "xargs -I",
        ]
        if destructivePatterns.contains(where: { cmd.contains($0) }) { return true }
        if cmd.contains("rm -") { return true }

        return false
    }
}
#endif
