//
//  AgentLoop.swift
//  Ora
//
//  Core agentic reasoning loop that processes user requests,
//  calls tools, and generates responses.
//

import Foundation
import os

/// Persistence sink for conversation messages emitted by AgentLoop.
protocol AgentLoopPersistenceSink: Sendable {
    func appendMessage(role: Session.Message.Role, content: String) async throws
}

struct SwiftDataAgentLoopPersistenceSink: AgentLoopPersistenceSink {
    func appendMessage(role: Session.Message.Role, content: String) async throws {
        await MainActor.run {
            _ = PersistenceManager.shared.appendMessage(role: role, content: content)
        }
    }
}

protocol AgentLoopSessionLifecycleSink: Sendable {
    func completeActiveSession() async -> UUID?
}

struct SwiftDataAgentLoopSessionLifecycleSink: AgentLoopSessionLifecycleSink {
    func completeActiveSession() async -> UUID? {
        return await MainActor.run {
            return PersistenceManager.shared.completeActiveSession()
        }
    }
}

/// Agent activity for transparency status updates
enum AgentActivity: Equatable, Sendable {
    /// Planning/reasoning before tool calls or response
    case planning
    /// About to call a tool
    case toolCall(name: String)
    /// Processing tool result
    case toolResult(name: String)
    /// Generating response text
    case composing
    /// Waiting for user follow-up
    case waiting
}

/// Result of an agent turn
enum AgentResult: Sendable {
    /// Direct response text
    case response(text: String)

    /// Authorization request requiring user approval
    case authorizationRequest(ToolProposal)
    
    /// Error during processing
    case error(String)
}

/// Delegate for agent loop events
@MainActor
protocol AgentLoopDelegate: AnyObject, Sendable {
    func agentLoopDidStartThinking(_ loop: AgentLoop)
    func agentLoop(_ loop: AgentLoop, didProduceToken token: String)
    func agentLoop(_ loop: AgentLoop, didRequestConfirmation proposal: ToolProposal)
    func agentLoop(_ loop: AgentLoop, didExecuteTool name: String, result: String)
    func agentLoop(_ loop: AgentLoop, didUpdateActivity activity: AgentActivity)
}

/// Pending proposal awaiting user confirmation
struct PendingAuthorization: Sendable {
    let ticket: ToolExecutionTicket
    let prompt: ToolAuthorizationPrompt

    var tool: String {
        self.ticket.toolName
    }

    var summary: String {
        self.prompt.summary
    }
}

/// Core agent loop for agentic tool use
///
/// Processes user input through the structured LLM flow:
/// 1. Build messages with system prompt including tool definitions
/// 2. Generate structured JSON response
/// 3. Parse response type (response/tool_call/proposal)
/// 4. For tool_call: execute and loop back
/// 5. For proposal: return to orchestrator for confirmation
/// 6. For response: return final text
actor AgentLoop {
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "AgentLoop")
    
    // Use MainActor-isolated delegate holder pattern
    @MainActor private weak var _delegate: AgentLoopDelegate?
    
    // Policy limits
    private let maxStepsPerTurn: Int
    private let maxToolCallsPerTurn: Int
    private let maxTokensPerTurn: Int
    private let maxPersistedToolSummaryCharacters: Int = 500
    
    private var currentSessionID: UUID?
    private var toolDiscoveryFallbackSessionID: UUID?
    private var sessionSkills: [SkillMetadata] = []
    private var lastSystemPromptHash: Int?
    
    /// Whether a session is active (conversation has been initialized)
    private var sessionActive: Bool = false
    
    /// Pending proposal awaiting user confirmation
    private var pendingAuthorization: PendingAuthorization?
    
    /// Current activity state to prevent duplicate updates
    private var currentActivity: AgentActivity?
    
    // Dependencies (injectable for testing)
    private let structuredGenerator: StructuredGenerator
    private let toolHost: ToolHost
    private let toolRegistry: ToolRegistry
    private let conversationManager: ConversationManager
    private let persistenceSink: AgentLoopPersistenceSink
    private let sessionLifecycleSink: AgentLoopSessionLifecycleSink
    private let memoryDistiller: any MemoryDistilling
    private let memoryTriggerDetector: any MemoryTriggerDetecting
    private let memoryRetrievalCoordinator: any MemoryRetrievalCoordinating
    
    // MARK: - Initialization
    
    init(
        maxStepsPerTurn: Int = 6,
        maxToolCallsPerTurn: Int = 3,
        maxTokensPerTurn: Int = 800,
        structuredGenerator: StructuredGenerator = StructuredGenerator(llm: LLMProviderManager.shared),
        toolHost: ToolHost = .shared,
        toolRegistry: ToolRegistry = .shared,
        conversationManager: ConversationManager = .shared,
        persistenceSink: AgentLoopPersistenceSink = SwiftDataAgentLoopPersistenceSink(),
        sessionLifecycleSink: AgentLoopSessionLifecycleSink = SwiftDataAgentLoopSessionLifecycleSink(),
        memoryDistiller: any MemoryDistilling = MemoryDistiller.shared,
        memoryTriggerDetector: any MemoryTriggerDetecting = MemoryTriggerDetector(),
        memoryRetrievalCoordinator: any MemoryRetrievalCoordinating = KeywordMemoryRetrievalCoordinator()
    ) {
        self.maxStepsPerTurn = maxStepsPerTurn
        self.maxToolCallsPerTurn = maxToolCallsPerTurn
        self.maxTokensPerTurn = maxTokensPerTurn
        self.structuredGenerator = structuredGenerator
        self.toolHost = toolHost
        self.toolRegistry = toolRegistry
        self.conversationManager = conversationManager
        self.persistenceSink = persistenceSink
        self.sessionLifecycleSink = sessionLifecycleSink
        self.memoryDistiller = memoryDistiller
        self.memoryTriggerDetector = memoryTriggerDetector
        self.memoryRetrievalCoordinator = memoryRetrievalCoordinator
    }
    
    // MARK: - Public API
    
    /// Set the delegate for agent loop events
    @MainActor
    func setDelegate(_ delegate: AgentLoopDelegate?) {
        self._delegate = delegate
    }
    
    /// Start a new session with tool definitions
    ///
    /// This initializes the conversation with the system prompt containing
    /// tool schemas. Call this once at the start of a new session.
    ///
    /// - Parameter sessionID: Optional session ID for audit logging
    func startSession(sessionID: UUID? = nil) async {
        self.currentSessionID = sessionID
        self.toolDiscoveryFallbackSessionID = UUID()
        self.sessionActive = true
        self.pendingAuthorization = nil
        self.lastSystemPromptHash = nil
        
        logger.info("Starting new agent session")

        if await SkillsFeatureGate.isEnabled() {
            self.sessionSkills = await SkillStore.shared.list()
        } else {
            self.sessionSkills = []
        }

        if let sessionID = self.currentToolDiscoverySessionID() {
            await self.toolRegistry.clearDiscoveredTools(for: sessionID)
        }
        let systemPrompt = await self.buildSystemPrompt()
        self.lastSystemPromptHash = systemPrompt.hashValue
        
        // Start fresh conversation with system prompt
        await conversationManager.startConversation(systemPrompt: systemPrompt)
    }
    
    /// End the current session
    ///
    /// Clears all session state and conversation history to free memory.
    func endSession() async {
        if self.sessionActive {
            let completedSessionID = await self.sessionLifecycleSink.completeActiveSession()
            if let completedSessionID {
                let memoryDistiller = self.memoryDistiller
                Task.detached(priority: .utility) {
                    _ = await memoryDistiller.distill(sessionId: completedSessionID)
                }
            }
        }

        self.sessionActive = false
        self.pendingAuthorization = nil
        self.sessionSkills = []
        self.lastSystemPromptHash = nil

        let discoverySessions = self.activeToolDiscoverySessionIDs()
        for sessionID in discoverySessions {
            await self.toolRegistry.clearDiscoveredTools(for: sessionID)
        }

        self.currentSessionID = nil
        self.toolDiscoveryFallbackSessionID = nil
        
        // Clear conversation to free memory
        await conversationManager.clear()
        
        // Clear KV cache to free GPU memory
        await LLMProviderManager.shared.clearCache()
        
        logger.debug("Agent session ended")
    }
    
    /// Whether a session is currently active
    func isSessionActive() -> Bool {
        return sessionActive
    }
    
    /// Get the pending proposal (if any)
    func getPendingAuthorization() -> PendingAuthorization? {
        return pendingAuthorization
    }

    func getPendingProposal() -> PendingAuthorization? {
        return pendingAuthorization
    }
    
    /// Clear the pending proposal (on deny or cancel)
    func clearPendingAuthorization() async {
        if let pendingAuthorization {
            await self.toolHost.cancel(ticketID: pendingAuthorization.ticket.id)
        }
        pendingAuthorization = nil
    }

    func clearPendingProposal() async {
        await self.clearPendingAuthorization()
    }
    
    /// Process user input and return response (session-aware)
    ///
    /// If a session is already active, this continues the conversation.
    /// Otherwise, it starts a new session.
    ///
    /// - Parameters:
    ///   - userText: The user's input text
    ///   - sessionID: Optional session ID for audit logging (only used if starting new session)
    /// - Returns: The agent result (response, proposal, or error)
    func process(userText: String, sessionID: UUID? = nil) async throws -> AgentResult {
        // If no session is active, start one
        if !sessionActive {
            await startSession(sessionID: sessionID)
        } else if let sid = sessionID {
            if self.currentSessionID == nil, let fallbackSessionID = self.toolDiscoveryFallbackSessionID {
                await self.toolRegistry.migrateDiscoveredTools(from: fallbackSessionID, to: sid)
            }
            self.currentSessionID = sid
        }
        
        logger.info("Processing: \(userText.prefix(50))...")
        
        await notifyDelegateThinkingStarted()
        
        await self.persistMessage(role: .user, content: userText)

        // Clear stale memory context before adding the user message so that
        // trimContextIfNeeded() doesn't budget against the previous turn's payload.
        await self.conversationManager.clearMemoryContext()
        await conversationManager.addUserMessage(userText)

        let memoryTriggerResult = self.memoryTriggerDetector.detect(userText: userText)
        if memoryTriggerResult.shouldTrigger {
            self.logger.debug(
                "Memory retrieval trigger detected (\(memoryTriggerResult.triggerType.rawValue), confidence: \(memoryTriggerResult.confidence))"
            )
            self.logger.debug("Preparing memory retrieval context with transcript fallback if primary memory confidence is low")
        }
        await self.memoryRetrievalCoordinator.prepareRetrievalIfNeeded(
            userText: userText,
            triggerResult: memoryTriggerResult,
            conversationManager: self.conversationManager
        )
        
        // Run agent loop
        let result = await runLoop()
        
        return result
    }
    
    /// Continue processing after user confirms a proposal
    ///
    /// Called after the user confirms a proposal. Executes the tool
    /// and generates a follow-up response.
    ///
    /// - Parameters:
    ///   - tool: The tool name to execute
    ///   - args: The tool arguments
    /// - Returns: The tool execution result
    func executeAuthorizedPending(decision: ToolAuthorizationDecision) async throws -> ToolResult {
        guard let pendingAuthorization else {
            throw ToolHostError.invalidAuthorizationTicket
        }

        let tool = pendingAuthorization.ticket.toolName
        logger.info("Executing authorized tool: \(tool)")

        // Emit toolCall activity before execution
        await notifyDelegateActivity(.toolCall(name: tool))

        do {
            let receipt = try await self.toolHost.authorize(
                ticketID: pendingAuthorization.ticket.id,
                decision: decision
            )
            let execution = try await self.toolHost.executeAuthorized(
                ticket: pendingAuthorization.ticket,
                receipt: receipt
            )
            let result = execution.result
            self.pendingAuthorization = nil

            // Emit toolResult activity after execution
            await notifyDelegateActivity(.toolResult(name: tool))

            // Add to conversation context
            let resultText = "Tool \(tool) executed: \(result.humanSummary)"
            await conversationManager.addToolResult(resultText)
            await self.persistToolResultMessage(
                tool: tool,
                summary: result.humanSummary,
                auditID: execution.auditEntryID
            )

            await notifyDelegateToolExecuted(name: tool, result: result.humanSummary)

            logger.info("Tool \(tool) executed successfully: \(result.humanSummary)")
            return result
        } catch {
            // Emit toolResult even on failure
            await notifyDelegateActivity(.toolResult(name: tool))
            self.pendingAuthorization = nil

            logger.error("Tool \(tool) execution failed: \(error.localizedDescription)")
            throw error
        }
    }

    func executeConfirmedTool(
        tool: String,
        args: [String: JSONValue]
    ) async throws -> ToolResult {
        let preflight = try await self.toolHost.preflight(
            toolName: tool,
            args: args,
            sessionID: self.currentSessionID
        )

        guard case .requiresUser = preflight.disposition else {
            if case .allowed(let receipt) = preflight.disposition {
                let execution = try await self.toolHost.executeAuthorized(ticket: preflight.ticket, receipt: receipt)
                return execution.result
            }
            throw ToolHostError.confirmationRequired(tool)
        }

        self.pendingAuthorization = PendingAuthorization(
            ticket: preflight.ticket,
            prompt: ToolAuthorizationPrompt(title: "Confirm Action", summary: "Allow \(tool) to run?")
        )
        return try await self.executeAuthorizedPending(decision: .approveOnce)
    }
    
    /// Generate follow-up response after tool execution
    ///
    /// Called after a tool has been executed to generate the final
    /// response to the user.
    ///
    /// - Returns: The follow-up response text
    func generateFollowUp() async throws -> String {
        logger.info("Generating follow-up response")

        // Emit composing activity when starting to generate
        await notifyDelegateActivity(.composing)

        await refreshSystemPromptIfNeeded()

        let messages = await conversationManager.getMessagesForLLM()
        let output = try await structuredGenerator.generate(
            messages: messages,
            responseTokenHandler: { token in
                await self.notifyDelegateActivity(.composing)
                await self.notifyDelegateToken(token)
            }
        )
        
        if case .response(let text) = output {
            await self.persistMessage(role: .assistant, content: text)
            await conversationManager.addAssistantMessage(text)
            return text
        }
        
        // If not a direct response, return a simple acknowledgment
        let defaultResponse = "Done."
        await self.persistMessage(role: .assistant, content: defaultResponse)
        await conversationManager.addAssistantMessage(defaultResponse)
        return defaultResponse
    }
    
    /// Cancel current processing
    func cancel() {
        logger.debug("Agent loop cancelled")
        // Task cancellation is handled by the caller
    }
    
    // MARK: - Private - Loop Execution
    
    private func runLoop() async -> AgentResult {
        var steps = 0
        var toolCalls = 0

        while steps < maxStepsPerTurn {
            steps += 1
            logger.debug("Agent loop step \(steps)/\(self.maxStepsPerTurn)")

            await refreshSystemPromptIfNeeded()

            // Emit planning activity before each generation step
            await notifyDelegateActivity(.planning)

            let messages = await conversationManager.getMessagesForLLM()
            logger.info("Agent step \(steps): sending \(messages.count) messages to LLM")

            // Generate structured response
            let output: LLMOutput
            do {
                output = try await structuredGenerator.generate(
                    messages: messages,
                    responseTokenHandler: { token in
                        await self.notifyDelegateActivity(.composing)
                        await self.notifyDelegateToken(token)
                    }
                )
            } catch {
                logger.error("Generation failed: \(error.localizedDescription)")
                if error is StructuredGeneratorError {
                    logger.error("AGENT_GENERATION_FAILED_STRUCTURED_OUTPUT")
                    return .error("I ran into a model formatting issue. Please try again, or switch models in Preferences > Providers.")
                }
                if let guidance = self.userFacingConfigurationMessage(for: error) {
                    logger.notice("AGENT_GENERATION_FAILED_WITH_CONFIGURATION_GUIDANCE")
                    return .error(guidance)
                }
                logger.error("AGENT_GENERATION_FAILED_GENERIC")
                return .error("I had trouble generating a response. Please try again.")
            }

            logger.info("Agent step \(steps): LLM decided \(output.typeLabel)")

            switch output {
            case .response(let text):
                // Direct response - we're done
                // Emit composing activity before returning response
                await notifyDelegateActivity(.composing)
                logger.info("Agent produced direct response")
                await self.persistMessage(role: .assistant, content: text)
                await conversationManager.addAssistantMessage(text)
                return .response(text: text)

            case .toolCall(let tool, let args):
                // Read-only tool call - execute automatically
                let countsTowardBudget = tool != ToolDiscoveryTool.toolName
                if countsTowardBudget {
                    guard toolCalls < maxToolCallsPerTurn else {
                        logger.warning("Tool call limit reached")
                        return .error("I've reached my limit for this request. Please try a simpler question.")
                    }
                    toolCalls += 1
                } else {
                    logger.debug("tools.discover exempt from business tool-call budget")
                }

                let executionArgs = self.preparedArgsForExecution(tool: tool, args: args)

                logger.info("Executing tool: \(tool) args=\(executionArgs.keys.sorted().joined(separator: ","))")

                // Emit toolCall activity before execution
                await notifyDelegateActivity(.toolCall(name: tool))

                do {
                    let preflight = try await self.toolHost.preflight(
                        toolName: tool,
                        args: executionArgs,
                        sessionID: currentSessionID
                    )
                    let execution: ToolExecutionRecord

                    switch preflight.disposition {
                    case .allowed(let receipt):
                        execution = try await self.toolHost.executeAuthorized(
                            ticket: preflight.ticket,
                            receipt: receipt
                        )

                    case .requiresUser(let prompt):
                        self.pendingAuthorization = PendingAuthorization(ticket: preflight.ticket, prompt: prompt)
                        return .authorizationRequest(self.toolProposal(for: tool, prompt: prompt))
                    }
                    let result = execution.result

                    // Emit toolResult activity after execution
                    await notifyDelegateActivity(.toolResult(name: tool))

                    await notifyDelegateToolExecuted(name: tool, result: result.humanSummary)

                    // Add result to context for next iteration
                    // Include full JSON data so LLM can see details like event IDs
                    let jsonString = result.json.compactJSON
                    let resultText = "Tool \(tool) returned: \(jsonString)"
                    logger.info("Tool result received for \(tool)")
                    await conversationManager.addToolResult(resultText)
                    await self.persistToolResultMessage(
                        tool: tool,
                        summary: result.humanSummary,
                        auditID: execution.auditEntryID
                    )

                } catch {
                    // Emit toolResult even on failure
                    await notifyDelegateActivity(.toolResult(name: tool))

                    // Tool failed, add error to context and continue
                    let failureSummary: String
                    let auditID: UUID?
                    if let executionError = error as? ToolExecutionError {
                        failureSummary = executionError.message
                        auditID = executionError.auditEntryID
                    } else {
                        failureSummary = error.localizedDescription
                        auditID = nil
                    }
                    let errorText = "Tool \(tool) failed: \(failureSummary)"
                    logger.error("Tool failed: \(errorText)")
                    await conversationManager.addToolResult(errorText)
                    if let auditID {
                        await self.persistToolResultMessage(
                            tool: tool,
                            summary: failureSummary,
                            auditID: auditID
                        )
                    } else {
                        logger.error("Missing audit entry ID for tool failure: \(tool)")
                    }
                }

                // Continue loop for next step
                continue
                
            case .proposal(let summary, let tool, let args):
                logger.info("Agent proposing: \(summary)")
                do {
                    let request = try await self.authorizationRequest(
                        tool: tool,
                        args: args,
                        preferredSummary: summary
                    )
                    return .authorizationRequest(request)
                } catch {
                    logger.error("Failed to prepare authorization request for \(tool): \(error.localizedDescription)")
                    return .error(error.localizedDescription)
                }
                
            case .error(let message):
                logger.warning("LLM returned error: \(message)")
                return .error(message)
            }
        }
        
        // Budget exhausted
        logger.warning("Agent loop budget exhausted after \(steps) steps")
        return .error("I wasn't able to complete that request. Could you try something simpler?")
    }

    // MARK: - Private - Prompt Refresh

    private func refreshSystemPromptIfNeeded() async {
        guard self.sessionActive else {
            return
        }

        if await SkillsFeatureGate.isEnabled() {
            self.sessionSkills = await SkillStore.shared.list()
        } else {
            self.sessionSkills = []
        }

        let prompt = await self.buildSystemPrompt()
        let promptHash = prompt.hashValue

        guard self.lastSystemPromptHash != promptHash else {
            return
        }

        self.lastSystemPromptHash = promptHash
        await self.conversationManager.updateSystemPrompt(prompt)
        self.logger.debug("Updated system prompt for active session")
    }

    private func buildSystemPrompt() async -> String {
        let coreSchemas = await self.toolRegistry.coreSchemas()
        let deferredCatalogRows = await self.toolRegistry.deferredCatalogRows()
        let discoveredSchemas: [ToolSchema]

        if let sessionID = self.currentToolDiscoverySessionID() {
            discoveredSchemas = await self.toolRegistry.discoveredSchemas(for: sessionID)
        } else {
            discoveredSchemas = []
        }

        let coreTools = coreSchemas.map { Self.toolDefinition(from: $0) }
        let discoveredTools = discoveredSchemas.map { Self.toolDefinition(from: $0) }
        let deferredCatalog = deferredCatalogRows.map { row in
            DeferredToolCatalogEntry(
                domain: row.domain,
                name: row.name,
                requiresConfirmation: row.requiresConfirmation
            )
        }

        return SystemPromptBuilder.build(
            tools: coreTools,
            deferredCatalog: deferredCatalog,
            discoveredTools: discoveredTools,
            skills: self.sessionSkills
        )
    }

    private func currentToolDiscoverySessionID() -> UUID? {
        self.currentSessionID ?? self.toolDiscoveryFallbackSessionID
    }

    private func activeToolDiscoverySessionIDs() -> Set<UUID> {
        var ids: Set<UUID> = []
        if let current = self.currentSessionID {
            ids.insert(current)
        }
        if let fallback = self.toolDiscoveryFallbackSessionID {
            ids.insert(fallback)
        }
        return ids
    }

    private func preparedArgsForExecution(tool: String, args: [String: JSONValue]) -> [String: JSONValue] {
        guard tool == ToolDiscoveryTool.toolName,
              let sessionID = self.currentToolDiscoverySessionID() else {
            return args
        }

        var prepared = args
        prepared[ToolDiscoveryTool.sessionIDArgumentKey] = .string(sessionID.uuidString)
        return prepared
    }

    private static func toolDefinition(from schema: ToolSchema) -> ToolDefinition {
        ToolDefinition(
            name: schema.name,
            description: schema.description,
            parameterSchemas: schema.parameters.mapValues { parameter in
                ToolParameterDefinition(type: parameter.type, format: parameter.format)
            },
            requiredParameters: schema.requiredParameters,
            requiresConfirmation: schema.requiresConfirmation
        )
    }

    private func authorizationRequest(
        tool: String,
        args: [String: JSONValue],
        preferredSummary: String?
    ) async throws -> ToolProposal {
        let executionArgs = self.preparedArgsForExecution(tool: tool, args: args)
        let preflight = try await self.toolHost.preflight(
            toolName: tool,
            args: executionArgs,
            sessionID: self.currentSessionID
        )

        switch preflight.disposition {
        case .requiresUser(let prompt):
            let customizedPrompt = self.prompt(prompt, overridingSummaryWith: preferredSummary)
            self.pendingAuthorization = PendingAuthorization(ticket: preflight.ticket, prompt: customizedPrompt)
            return self.toolProposal(for: tool, prompt: customizedPrompt)

        case .allowed:
            await self.toolHost.cancel(ticketID: preflight.ticket.id)
            throw ToolHostError.confirmationRequired(tool)
        }
    }

    private func prompt(
        _ prompt: ToolAuthorizationPrompt,
        overridingSummaryWith summary: String?
    ) -> ToolAuthorizationPrompt {
        guard let summary, !summary.isEmpty else {
            return prompt
        }

        return ToolAuthorizationPrompt(
            title: prompt.title,
            summary: summary,
            details: prompt.details,
            confirmLabel: prompt.confirmLabel,
            cancelLabel: prompt.cancelLabel,
            trustLabel: prompt.trustLabel,
            presentation: prompt.presentation
        )
    }

    private func toolProposal(for toolName: String, prompt: ToolAuthorizationPrompt) -> ToolProposal {
        ToolProposal(
            toolName: toolName,
            title: prompt.title,
            summary: prompt.summary,
            details: prompt.details,
            confirmLabel: prompt.confirmLabel,
            cancelLabel: prompt.cancelLabel,
            trustLabel: prompt.trustLabel,
            presentation: prompt.presentation
        )
    }
    
    // MARK: - Private - Delegate Notifications

    private func persistMessage(role: Session.Message.Role, content: String) async {
        do {
            try await self.persistenceSink.appendMessage(role: role, content: content)
        } catch {
            self.logger.error("Failed to persist \(role.rawValue) message: \(error.localizedDescription)")
        }
    }
    
    private func notifyDelegateThinkingStarted() async {
        await MainActor.run {
            self._delegate?.agentLoopDidStartThinking(self)
        }
    }

    private func persistToolResultMessage(
        tool: String,
        summary: String,
        auditID: UUID
    ) async {
        let boundedSummary = self.boundedToolSummary(summary)
        let auditReference = auditID.uuidString
        let content = "[ToolResult: \(tool)] \(boundedSummary) (auditId=\(auditReference))"
        await self.persistMessage(role: .tool, content: content)
    }

    private func boundedToolSummary(_ summary: String) -> String {
        let compactSummary = summary
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard compactSummary.count > self.maxPersistedToolSummaryCharacters else {
            return compactSummary
        }

        let prefixLength = max(self.maxPersistedToolSummaryCharacters - 3, 0)
        return "\(compactSummary.prefix(prefixLength))..."
    }

    private func notifyDelegateToken(_ token: String) async {
        await MainActor.run {
            self._delegate?.agentLoop(self, didProduceToken: token)
        }
    }
    
    private func notifyDelegateToolExecuted(name: String, result: String) async {
        await MainActor.run {
            self._delegate?.agentLoop(self, didExecuteTool: name, result: result)
        }
    }

    private func notifyDelegateActivity(_ activity: AgentActivity) async {
        if currentActivity == activity { return }
        currentActivity = activity

        await MainActor.run {
            self._delegate?.agentLoop(self, didUpdateActivity: activity)
        }
    }

    private func userFacingConfigurationMessage(for error: Error) -> String? {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .providerNotRegistered(let type):
                return "\(type.displayName) is not ready. Open Preferences > Providers, or switch to Local (Qwen 3 4B)."
            case .noCredential(let type):
                return "\(type.displayName) is not configured. Open Preferences > Providers to set up a connection."
            case .invalidModel(let type, _):
                return "The selected \(type.displayName) model is unavailable. Choose another model in Preferences > Providers."
            case .switchFailed(let type, _):
                return "I could not connect to \(type.displayName). Open Preferences > Providers, or switch to Local (Qwen 3 4B)."
            }
        }

        if let cloudError = error as? CloudProviderError {
            switch cloudError {
            case .authenticationFailed:
                return "Your cloud provider credential appears invalid. Open Preferences > Providers to reconnect."
            case .billingError:
                return "Your cloud provider account needs billing attention. Open Preferences > Providers or switch to Local (Qwen 3 4B)."
            case .connectionFailed:
                return "I could not reach the cloud provider. Check your connection or switch to Local (Qwen 3 4B)."
            case .requestFailed(let statusCode, let body):
                return self.requestFailureGuidance(statusCode: statusCode, body: body)
            case .invalidResponse(let reason):
                let normalized = reason.lowercased()
                if normalized.contains("model") && normalized.contains("unsupported") {
                    return "The selected cloud model is unavailable for this account. Choose another model in Preferences > Providers."
                }
                return nil
            case .rateLimited, .serverError:
                return nil
            }
        }

        return nil
    }

    private func requestFailureGuidance(statusCode: Int, body: String) -> String? {
        let normalized = body.lowercased()

        if normalized.contains("model") &&
            (normalized.contains("not found") ||
                normalized.contains("does not exist") ||
                normalized.contains("invalid model") ||
                normalized.contains("unsupported")) {
            return "The selected cloud model is unavailable for this account. Choose another model in Preferences > Providers."
        }

        if normalized.contains("max_tokens") ||
            normalized.contains("max_output_tokens") ||
            normalized.contains("max_completion_tokens") {
            return "The selected cloud model rejected this request format. Try another model in Preferences > Providers."
        }

        if normalized.contains("invalid_request_error") ||
            normalized.contains("invalid value") ||
            normalized.contains("unsupported value") ||
            normalized.contains("invalid type") ||
            normalized.contains("validation") ||
            normalized.contains("\"role\"") ||
            normalized.contains("messages") ||
            normalized.contains("input") ||
            normalized.contains("tool_choice") {
            return "The selected cloud model rejected Ora's structured request format. Try again or switch models in Preferences > Providers."
        }

        if normalized.contains("context length") ||
            normalized.contains("maximum context") ||
            normalized.contains("too many tokens") {
            return "This request exceeded the model context limit. Try a shorter prompt, or switch models in Preferences > Providers."
        }

        switch statusCode {
        case 400:
            return "The cloud provider rejected this request. Try again, or switch models in Preferences > Providers."
        case 401:
            return "Your cloud provider credential appears invalid. Open Preferences > Providers to reconnect."
        case 403:
            return "Your cloud provider account does not have access to this model. Choose another model in Preferences > Providers."
        case 404:
            return "The selected cloud model could not be found. Choose another model in Preferences > Providers."
        default:
            return nil
        }
    }
}
