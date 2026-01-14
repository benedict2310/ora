import OSLog

/// Centralized logging for Ora using Apple's Unified Logging system.
///
/// Usage:
/// ```swift
/// OraLog.llm.info("Starting inference")
/// OraLog.tools.debug("Tool call: \(toolName, privacy: .public)")
/// OraLog.audio.error("Capture failed: \(error.localizedDescription, privacy: .public)")
/// ```
///
/// Filter logs from CLI:
/// ```bash
/// ./build.sh logs                           # All Ora logs
/// ./build.sh logs --category llm            # Only LLM category
/// ./build.sh logs --predicate 'category == "tools"'
/// ```
enum OraLog {
    /// The subsystem identifier (bundle ID)
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.ora.app"
    
    // MARK: - Core Pipeline Categories
    
    /// Audio capture, VAD, and buffer operations
    static let audio = Logger(subsystem: subsystem, category: "audio")
    
    /// Automatic Speech Recognition (Parakeet engine)
    static let asr = Logger(subsystem: subsystem, category: "asr")
    
    /// LLM inference, context management, and generation
    static let llm = Logger(subsystem: subsystem, category: "llm")
    
    /// Tool execution (Calendar, Reminders, Contacts, System)
    static let tools = Logger(subsystem: subsystem, category: "tools")
    
    /// Text-to-speech synthesis (Kokoro engine)
    static let tts = Logger(subsystem: subsystem, category: "tts")
    
    // MARK: - Application Categories
    
    /// UI events, overlays, and user interactions
    static let ui = Logger(subsystem: subsystem, category: "ui")
    
    /// Orchestration and state machine transitions
    static let orchestration = Logger(subsystem: subsystem, category: "orchestration")
    
    /// Permissions and entitlements
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    
    /// Model loading and management
    static let models = Logger(subsystem: subsystem, category: "models")
    
    /// Persistence and SwiftData operations
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
}

// MARK: - Logging Best Practices
//
// 1. Use appropriate log levels:
//    - .debug:   Detailed debugging info (not persisted by default)
//    - .info:    General flow information
//    - .notice:  Important events (default visible level)
//    - .error:   Errors that don't crash
//    - .fault:   Critical errors (captured with stack traces)
//
// 2. Use privacy annotations for sensitive data:
//    OraLog.tools.info("Creating event: \(title, privacy: .public)")
//    OraLog.tools.debug("Contact ID: \(id, privacy: .private(mask: .hash))")
//
// 3. Keep log messages concise but informative:
//    - Include relevant identifiers
//    - Avoid logging large data structures
//    - Use structured data when possible
//
// 4. For performance-sensitive paths (audio callbacks), use .debug level
//    and avoid string interpolation in hot loops.
