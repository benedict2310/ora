//
//  ConversationManager.swift
//  Ora
//
//  Manages conversation context, message history, and token budgets
//

import Foundation
import os

/// Manages conversation state and context for multi-turn LLM interactions
///
/// Thread-safe actor that maintains conversation history, system prompts,
/// and automatic context window trimming using FIFO strategy.
actor ConversationManager {
    
    // MARK: - Singleton
    
    static let shared = ConversationManager()
    
    // MARK: - Properties
    
    private let logger = Logger.ora(category: "ConversationManager")
    // Qwen 3 4B supports 262K tokens; 32K is a conservative cap that leaves ~29K for conversation after the system prompt
    static let defaultMaxContextTokens: Int = 32_000
    
    private var messages: [LLMMessage] = []
    private var systemPrompt: String = ""
    private var memoryContext: String?
    
    /// Maximum tokens for context window (leaving room for response)
    private let maxContextTokens: Int
    
    /// Approximate tokens per character for estimation
    /// English text averages ~0.25-0.33 tokens per character
    private let tokensPerChar: Double = 0.3
    
    // MARK: - Initialization
    
    private init(maxContextTokens: Int = ConversationManager.defaultMaxContextTokens) {
        self.maxContextTokens = maxContextTokens
    }
    
    /// Create a test instance with custom token limit
    /// - Parameter maxContextTokens: Maximum tokens allowed before trimming
    static func makeTestInstance(maxContextTokens: Int = ConversationManager.defaultMaxContextTokens) -> ConversationManager {
        return ConversationManager(maxContextTokens: maxContextTokens)
    }
    
    // MARK: - Public API
    
    /// Start a new conversation with a system prompt
    /// - Parameter systemPrompt: The system prompt that defines assistant behavior
    func startConversation(systemPrompt: String) {
        self.systemPrompt = systemPrompt
        self.messages = []
        self.memoryContext = nil
        
        // Clear KV cache when starting a new conversation
        // This ensures the LLM doesn't reuse stale cached state
        Task {
            await LLMService.shared.clearCache()
        }
        
        logger.debug("Started new conversation with system prompt (\(systemPrompt.count) chars)")
    }
    
    /// Add a user message to the conversation
    /// - Parameter content: The user's message content
    func addUserMessage(_ content: String) {
        messages.append(LLMMessage(role: .user, content: content))
        trimContextIfNeeded()
        logger.debug("Added user message (\(content.count) chars), total messages: \(self.messages.count)")
    }
    
    /// Add an assistant message to the conversation
    /// - Parameter content: The assistant's response content
    func addAssistantMessage(_ content: String) {
        messages.append(LLMMessage(role: .assistant, content: content))
        trimContextIfNeeded()
        logger.debug("Added assistant message (\(content.count) chars), total messages: \(self.messages.count)")
    }
    
    /// Add a tool result to the conversation
    /// - Parameter content: The tool execution result
    func addToolResult(_ content: String) {
        messages.append(LLMMessage(role: .tool, content: content))
        trimContextIfNeeded()
        logger.debug("Added tool result (\(content.count) chars), total messages: \(self.messages.count)")
    }
    
    /// Get all messages formatted for LLM generation
    /// - Returns: Array of messages with system prompt as first element
    func getMessagesForLLM() -> [LLMMessage] {
        var result: [LLMMessage] = []
        
        // System prompt is always first (AC-1)
        if !self.systemPrompt.isEmpty {
            result.append(LLMMessage(role: .system, content: self.systemPrompt))
        }

        if let memoryContext = self.memoryContext,
            !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(LLMMessage(role: .system, content: memoryContext))
        }
        
        // Add conversation messages in order (AC-2)
        result.append(contentsOf: self.messages)
        
        return result
    }
    
    /// Get current conversation messages (without system prompt)
    /// - Returns: Array of conversation messages
    func getConversation() -> [LLMMessage] {
        return messages
    }
    
    /// Get the current system prompt
    /// - Returns: The system prompt string
    func getSystemPrompt() -> String {
        return systemPrompt
    }
    
    /// Get the current message count (excluding system prompt)
    /// - Returns: Number of messages in conversation
    func messageCount() -> Int {
        return messages.count
    }
    
    /// Estimate total tokens for current context
    /// - Returns: Estimated token count including system prompt and memory context
    func estimateTotalTokens() -> Int {
        var total = estimateTokens(systemPrompt)
        if let memoryContext {
            total += estimateTokens(memoryContext)
        }
        for message in messages {
            total += estimateTokens(message.content)
        }
        return total
    }
    
    /// Clear conversation state completely (AC-5)
    func clear() {
        self.messages = []
        self.systemPrompt = ""
        self.memoryContext = nil
        logger.debug("Conversation cleared")
    }

    func setMemoryContext(_ context: String?) {
        let normalized = context?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            self.memoryContext = normalized
            self.logger.debug("Injected memory context (\(normalized.count) chars)")
            trimContextIfNeeded()
        } else {
            self.memoryContext = nil
            self.logger.debug("Cleared memory context")
        }
    }

    func clearMemoryContext() {
        self.memoryContext = nil
        self.logger.debug("Cleared memory context")
    }
    
    // MARK: - Private
    
    /// Trim context using FIFO if over token budget (AC-3, AC-4)
    ///
    /// Trims oldest messages first. Will reduce down to 1 message if needed
    /// to stay under budget. If still over budget (due to oversized single message),
    /// logs a warning but preserves the message for context continuity.
    private func trimContextIfNeeded() {
        var totalTokens = estimateTokens(systemPrompt)
        if let memoryContext {
            totalTokens += estimateTokens(memoryContext)
        }

        for message in messages {
            totalTokens += estimateTokens(message.content)
        }
        
        // Keep at least 1 message for minimal context
        let minMessages = 1
        var trimCount = 0
        
        while totalTokens > maxContextTokens && messages.count > minMessages {
            let removed = messages.removeFirst()
            totalTokens -= estimateTokens(removed.content)
            trimCount += 1
        }
        
        if trimCount > 0 {
            logger.info("Trimmed \(trimCount) message(s) from context, remaining tokens: ~\(totalTokens)")
        }
        
        // Warn if still over budget (can happen with oversized single message)
        if totalTokens > maxContextTokens {
            logger.warning("Context still over budget (~\(totalTokens) tokens > \(self.maxContextTokens) max) after trimming - oversized message")
        }
    }
    
    /// Estimate token count for text (AC-6)
    /// - Parameter text: Text to estimate
    /// - Returns: Estimated token count
    private func estimateTokens(_ text: String) -> Int {
        Int(Double(text.count) * tokensPerChar)
    }
}
