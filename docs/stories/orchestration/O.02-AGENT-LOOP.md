# O.01 - Agent Loop

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2-3 days
**Dependencies:** L.01 (LLM), L.02 (Structured Output), X.01 (Tool Protocol)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement the core agentic reasoning loop that processes user requests, calls tools, and generates responses.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AgentLoop                             │
│                         (Actor)                              │
├─────────────────────────────────────────────────────────────┤
│  1. Receive user text                                       │
│  2. Build messages with system prompt                       │
│  3. Generate structured LLM response                        │
│  4. Parse response type (text/tool_call/proposal)          │
│  5. If tool: validate, execute (with confirmation)         │
│  6. Add tool result to context                             │
│  7. Repeat until response or budget exhausted              │
│  8. Return final response                                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

**File:** `Ora/Orchestration/AgentLoop.swift`

```swift
//
//  AgentLoop.swift
//  Ora
//
//  Core agentic reasoning loop
//

import Foundation
import os

/// Result of an agent turn
enum AgentResult: Sendable {
    case response(text: String)
    case proposal(summary: String, tool: String, args: [String: JSONValue])
    case error(String)
}

/// Delegate for agent loop events
protocol AgentLoopDelegate: AnyObject, Sendable {
    func agentLoop(_ loop: AgentLoop, didStartThinking: Void) async
    func agentLoop(_ loop: AgentLoop, didProduceToken token: String) async
    func agentLoop(_ loop: AgentLoop, didRequestConfirmation proposal: ToolProposal) async
    func agentLoop(_ loop: AgentLoop, didExecuteTool name: String, result: String) async
}

/// Core agent loop
actor AgentLoop {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "AgentLoop")
    
    weak var delegate: AgentLoopDelegate?
    
    // Policy limits
    private let maxStepsPerTurn = 6
    private let maxToolCallsPerTurn = 3
    private let maxTokensPerTurn = 800
    
    private var currentSessionID: UUID?
    
    // MARK: - Public API
    
    /// Process user input and return response
    func process(userText: String, sessionID: UUID? = nil) async throws -> AgentResult {
        currentSessionID = sessionID
        
        logger.info("Processing: \(userText.prefix(50))...")
        
        await delegate?.agentLoop(self, didStartThinking: ())
        
        // Build initial messages
        let systemPrompt = SystemPromptBuilder.build(
            tools: await ToolRegistry.shared.schemas().map { schema in
                ToolDefinition(
                    name: schema.name,
                    description: schema.description,
                    parameters: schema.parameters.mapValues { $0.description },
                    requiresConfirmation: schema.name.contains("create") || schema.name.contains("delete")
                )
            }
        )
        
        await ConversationManager.shared.startConversation(systemPrompt: systemPrompt)
        await ConversationManager.shared.addUserMessage(userText)
        
        // Run agent loop
        var steps = 0
        var toolCalls = 0
        
        while steps < maxStepsPerTurn {
            steps += 1
            
            let messages = await ConversationManager.shared.getMessagesForLLM()
            
            // Generate structured response
            let output: LLMOutput
            do {
                output = try await StructuredGenerator().generate(messages: messages)
            } catch {
                logger.error("Generation failed: \(error.localizedDescription)")
                return .error("I had trouble understanding that. Could you try again?")
            }
            
            switch output {
            case .response(let text):
                // Direct response - we're done
                await ConversationManager.shared.addAssistantMessage(text)
                return .response(text: text)
                
            case .toolCall(let tool, let args):
                // Read-only tool call
                guard toolCalls < maxToolCallsPerTurn else {
                    return .error("I've reached my limit for this request. Please try a simpler question.")
                }
                toolCalls += 1
                
                do {
                    let result = try await ToolHost.shared.execute(
                        toolName: tool,
                        args: args,
                        confirmed: true,  // Read tools don't need confirmation
                        sessionID: sessionID
                    )
                    
                    await delegate?.agentLoop(self, didExecuteTool: tool, result: result.humanSummary)
                    
                    // Add result to context
                    let resultText = "Tool \(tool) returned: \(result.humanSummary)"
                    await ConversationManager.shared.addToolResult(resultText)
                    
                } catch {
                    // Tool failed, add error to context
                    let errorText = "Tool \(tool) failed: \(error.localizedDescription)"
                    await ConversationManager.shared.addToolResult(errorText)
                }
                
                // Continue loop for next step
                continue
                
            case .proposal(let summary, let tool, let args):
                // Mutation requires confirmation - return to orchestrator
                return .proposal(summary: summary, tool: tool, args: args)
                
            case .error(let message):
                return .error(message)
            }
        }
        
        // Budget exhausted
        logger.warning("Agent loop budget exhausted after \(steps) steps")
        return .error("I wasn't able to complete that request. Could you try something simpler?")
    }
    
    /// Execute a confirmed tool call
    func executeConfirmedTool(
        tool: String,
        args: [String: JSONValue]
    ) async throws -> ToolResult {
        let result = try await ToolHost.shared.execute(
            toolName: tool,
            args: args,
            confirmed: true,
            sessionID: currentSessionID
        )
        
        // Add to conversation context
        let resultText = "Tool \(tool) executed: \(result.humanSummary)"
        await ConversationManager.shared.addToolResult(resultText)
        
        return result
    }
    
    /// Generate follow-up response after tool execution
    func generateFollowUp() async throws -> String {
        let messages = await ConversationManager.shared.getMessagesForLLM()
        let output = try await StructuredGenerator().generate(messages: messages)
        
        if case .response(let text) = output {
            await ConversationManager.shared.addAssistantMessage(text)
            return text
        }
        
        return "Done."
    }
    
    /// Cancel current processing
    func cancel() {
        logger.debug("Agent loop cancelled")
    }
}
```

---

## 4. Acceptance Criteria

- [ ] **AC-1:** Processes user text through LLM
- [ ] **AC-2:** Handles response/tool_call/proposal types
- [ ] **AC-3:** Executes read-only tools automatically
- [ ] **AC-4:** Returns proposals for mutations
- [ ] **AC-5:** Respects step and tool call limits
- [ ] **AC-6:** Adds tool results to conversation context
- [ ] **AC-7:** Generates follow-up after tool execution

---

## 5. Implementation Checklist

- [ ] Create `AgentLoop.swift`
- [ ] Integrate with StructuredGenerator
- [ ] Integrate with ToolHost
- [ ] Integrate with ConversationManager
- [ ] Test multi-step reasoning
- [ ] Test budget limits
