//
//  AgentLoop.swift
//  Ora
//
//  Core agentic reasoning loop that processes user requests,
//  calls tools, and generates responses.
//

import Foundation
import os

/// Result of an agent turn
enum AgentResult: Sendable {
    /// Direct response text
    case response(text: String)
    
    /// Proposal for mutation requiring confirmation
    case proposal(summary: String, tool: String, args: [String: JSONValue])
    
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
}

/// Pending proposal awaiting user confirmation
struct PendingProposal: Sendable {
    let summary: String
    let tool: String
    let args: [String: JSONValue]
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
    
    private let logger = Logger(subsystem: "com.ora.app", category: "AgentLoop")
    
    // Use MainActor-isolated delegate holder pattern
    @MainActor private weak var _delegate: AgentLoopDelegate?
    
    // Policy limits
    private let maxStepsPerTurn: Int
    private let maxToolCallsPerTurn: Int
    private let maxTokensPerTurn: Int
    
    private var currentSessionID: UUID?
    
    /// Whether a session is active (conversation has been initialized)
    private var sessionActive: Bool = false
    
    /// Pending proposal awaiting user confirmation
    private var pendingProposal: PendingProposal?
    
    // Dependencies (injectable for testing)
    private let structuredGenerator: StructuredGenerator
    private let toolHost: ToolHost
    private let toolRegistry: ToolRegistry
    private let conversationManager: ConversationManager
    
    // MARK: - Initialization
    
    init(
        maxStepsPerTurn: Int = 6,
        maxToolCallsPerTurn: Int = 3,
        maxTokensPerTurn: Int = 800,
        structuredGenerator: StructuredGenerator = StructuredGenerator(),
        toolHost: ToolHost = .shared,
        toolRegistry: ToolRegistry = .shared,
        conversationManager: ConversationManager = .shared
    ) {
        self.maxStepsPerTurn = maxStepsPerTurn
        self.maxToolCallsPerTurn = maxToolCallsPerTurn
        self.maxTokensPerTurn = maxTokensPerTurn
        self.structuredGenerator = structuredGenerator
        self.toolHost = toolHost
        self.toolRegistry = toolRegistry
        self.conversationManager = conversationManager
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
        self.sessionActive = true
        self.pendingProposal = nil
        
        logger.info("Starting new agent session")
        
        // Build system prompt with tool definitions
        let toolSchemas = await toolRegistry.schemas()
        let toolDefinitions = toolSchemas.map { schema in
            ToolDefinition(
                name: schema.name,
                description: schema.description,
                parameters: schema.parameters.mapValues { $0.descriptionString },
                requiresConfirmation: schema.requiresConfirmation
            )
        }
        
        let systemPrompt = SystemPromptBuilder.build(tools: toolDefinitions)
        
        // Start fresh conversation with system prompt
        await conversationManager.startConversation(systemPrompt: systemPrompt)
    }
    
    /// End the current session
    func endSession() {
        self.sessionActive = false
        self.pendingProposal = nil
        self.currentSessionID = nil
        logger.debug("Agent session ended")
    }
    
    /// Whether a session is currently active
    func isSessionActive() -> Bool {
        return sessionActive
    }
    
    /// Get the pending proposal (if any)
    func getPendingProposal() -> PendingProposal? {
        return pendingProposal
    }
    
    /// Clear the pending proposal (on deny or cancel)
    func clearPendingProposal() {
        pendingProposal = nil
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
            self.currentSessionID = sid
        }
        
        logger.info("Processing: \(userText.prefix(50))...")
        
        await notifyDelegateThinkingStarted()
        
        // Add user message to existing conversation
        await conversationManager.addUserMessage(userText)
        
        // Run agent loop
        let result = await runLoop()
        
        // Store proposal for later execution if needed
        if case .proposal(let summary, let tool, let args) = result {
            self.pendingProposal = PendingProposal(summary: summary, tool: tool, args: args)
        }
        
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
    func executeConfirmedTool(
        tool: String,
        args: [String: JSONValue]
    ) async throws -> ToolResult {
        logger.info("Executing confirmed tool: \(tool) with args: \(args.keys.joined(separator: ", "))")
        
        do {
            let result = try await toolHost.execute(
                toolName: tool,
                args: args,
                confirmed: true,
                sessionID: currentSessionID
            )
            
            // Add to conversation context
            let resultText = "Tool \(tool) executed: \(result.humanSummary)"
            await conversationManager.addToolResult(resultText)
            
            await notifyDelegateToolExecuted(name: tool, result: result.humanSummary)
            
            logger.info("Tool \(tool) executed successfully: \(result.humanSummary)")
            return result
        } catch {
            logger.error("Tool \(tool) execution failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Generate follow-up response after tool execution
    ///
    /// Called after a tool has been executed to generate the final
    /// response to the user.
    ///
    /// - Returns: The follow-up response text
    func generateFollowUp() async throws -> String {
        logger.info("Generating follow-up response")
        
        let messages = await conversationManager.getMessagesForLLM()
        let output = try await structuredGenerator.generate(messages: messages)
        
        if case .response(let text) = output {
            await conversationManager.addAssistantMessage(text)
            return text
        }
        
        // If not a direct response, return a simple acknowledgment
        let defaultResponse = "Done."
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
            
            let messages = await conversationManager.getMessagesForLLM()
            
            // Generate structured response
            let output: LLMOutput
            do {
                output = try await structuredGenerator.generate(messages: messages)
            } catch {
                logger.error("Generation failed: \(error.localizedDescription)")
                return .error("I had trouble understanding that. Could you try again?")
            }
            
            switch output {
            case .response(let text):
                // Direct response - we're done
                logger.info("Agent produced response: \(text.prefix(50))...")
                await conversationManager.addAssistantMessage(text)
                return .response(text: text)
                
            case .toolCall(let tool, let args):
                // Read-only tool call - execute automatically
                guard toolCalls < maxToolCallsPerTurn else {
                    logger.warning("Tool call limit reached")
                    return .error("I've reached my limit for this request. Please try a simpler question.")
                }
                toolCalls += 1
                
                logger.info("Executing tool: \(tool)")
                
                do {
                    let result = try await toolHost.execute(
                        toolName: tool,
                        args: args,
                        confirmed: true,  // Read tools don't need confirmation
                        sessionID: currentSessionID
                    )
                    
                    await notifyDelegateToolExecuted(name: tool, result: result.humanSummary)

                    // Add result to context for next iteration
                    // Include full JSON data so LLM can see details like event IDs
                    let jsonString = result.json.compactJSON
                    let resultText = "Tool \(tool) returned: \(jsonString)"
                    await conversationManager.addToolResult(resultText)
                    
                } catch {
                    // Tool failed, add error to context and continue
                    let errorText = "Tool \(tool) failed: \(error.localizedDescription)"
                    logger.warning("Tool failed: \(errorText)")
                    await conversationManager.addToolResult(errorText)
                }
                
                // Continue loop for next step
                continue
                
            case .proposal(let summary, let tool, let args):
                // Mutation requires confirmation - return to orchestrator
                logger.info("Agent proposing: \(summary)")
                return .proposal(summary: summary, tool: tool, args: args)
                
            case .error(let message):
                logger.warning("LLM returned error: \(message)")
                return .error(message)
            }
        }
        
        // Budget exhausted
        logger.warning("Agent loop budget exhausted after \(steps) steps")
        return .error("I wasn't able to complete that request. Could you try something simpler?")
    }
    
    // MARK: - Private - Delegate Notifications
    
    private func notifyDelegateThinkingStarted() async {
        await MainActor.run {
            self._delegate?.agentLoopDidStartThinking(self)
        }
    }
    
    private func notifyDelegateToolExecuted(name: String, result: String) async {
        await MainActor.run {
            self._delegate?.agentLoop(self, didExecuteTool: name, result: result)
        }
    }
}
