# O.03 - Confirmation Flow

**Epic:** Orchestration
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 1-2 days
**Dependencies:** O.01 (Agent Loop), F.07 (Overlay Window)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Liquid Glass UI Guide](../../references/liquid-glass-ui.md)

---

## 1. Objective

Implement the UI-driven confirmation flow for tool mutations. When the agent proposes a state-changing action (create event, delete reminder, etc.), the user must explicitly confirm before execution.

### Key Requirements

1. **Explicit Consent:** Mutations require user approval
2. **Clear Preview:** Show exactly what will change
3. **Timeout Safety:** Auto-cancel after 60 seconds
4. **Keyboard Shortcuts:** Return to confirm, Escape to deny
5. **Undo Tracking:** Store undo actions for confirmed operations

---

## 2. Architecture

### Confirmation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Confirmation Flow                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  1. Agent proposes mutation                                                 │
│     └─► AgentLoop returns .proposal(summary, tool, args)                   │
│                                                                              │
│  2. Orchestrator shows confirmation UI                                      │
│     └─► ConfirmationView displayed in overlay                              │
│     └─► 60-second timeout started                                          │
│                                                                              │
│  3. User decision                                                           │
│     ├─► Confirm (Return key or button)                                     │
│     │   └─► Tool executes via ToolHost                                     │
│     │   └─► Result logged to audit                                         │
│     │   └─► Undo action stored                                             │
│     │   └─► Follow-up response generated                                   │
│     │                                                                       │
│     ├─► Deny (Escape key or button)                                        │
│     │   └─► Polite acknowledgment                                          │
│     │   └─► No tool execution                                              │
│     │                                                                       │
│     └─► Timeout (60 seconds)                                               │
│         └─► Auto-cancel with timeout message                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ConfirmationManager                                   │
│                          (@MainActor)                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  State:                          Methods:                                   │
│  ├─ pendingProposal             ├─ showConfirmation(proposal)              │
│  ├─ timeoutTask                 ├─ confirm()                               │
│  └─ undoStack                   ├─ deny()                                  │
│                                 └─ undo() -> last action                   │
│                                                                              │
│  Delegates to:                                                              │
│  └─ ConversationOrchestrator                                               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 Confirmation State

**File:** `Ora/Orchestration/ConfirmationState.swift`

```swift
//
//  ConfirmationState.swift
//  Ora
//
//  State for the confirmation flow
//

import Foundation

/// A pending confirmation request
struct PendingConfirmation: Identifiable, Sendable {
    let id: UUID
    let toolName: String
    let summary: String
    let details: ConfirmationDetails
    let args: [String: JSONValue]
    let timestamp: Date
    let timeoutAt: Date
    
    init(
        toolName: String,
        summary: String,
        details: ConfirmationDetails,
        args: [String: JSONValue],
        timeout: TimeInterval = 60
    ) {
        self.id = UUID()
        self.toolName = toolName
        self.summary = summary
        self.details = details
        self.args = args
        self.timestamp = Date()
        self.timeoutAt = Date().addingTimeInterval(timeout)
    }
    
    /// Time remaining until timeout
    var timeRemaining: TimeInterval {
        max(0, timeoutAt.timeIntervalSince(Date()))
    }
    
    /// Whether the confirmation has timed out
    var isTimedOut: Bool {
        timeRemaining <= 0
    }
}

/// Details about what will be changed
struct ConfirmationDetails: Sendable {
    let actionType: ActionType
    let targetDescription: String
    let previewLines: [PreviewLine]
    
    enum ActionType: String, Sendable {
        case create = "Create"
        case update = "Update"
        case delete = "Delete"
    }
    
    struct PreviewLine: Identifiable, Sendable {
        let id = UUID()
        let label: String
        let value: String
        let isHighlighted: Bool
        
        init(label: String, value: String, highlighted: Bool = false) {
            self.label = label
            self.value = value
            self.isHighlighted = highlighted
        }
    }
}

/// Stored undo action for reversing a confirmed operation
struct UndoAction: Identifiable, Sendable {
    let id: UUID
    let toolName: String
    let description: String
    let undoToolName: String
    let undoArgs: [String: JSONValue]
    let timestamp: Date
    let expiresAt: Date
    
    init(
        toolName: String,
        description: String,
        undoToolName: String,
        undoArgs: [String: JSONValue],
        validFor: TimeInterval = 300  // 5 minutes
    ) {
        self.id = UUID()
        self.toolName = toolName
        self.description = description
        self.undoToolName = undoToolName
        self.undoArgs = undoArgs
        self.timestamp = Date()
        self.expiresAt = Date().addingTimeInterval(validFor)
    }
    
    var isExpired: Bool {
        Date() > expiresAt
    }
}
```

### 3.2 Confirmation Manager

**File:** `Ora/Orchestration/ConfirmationManager.swift`

```swift
//
//  ConfirmationManager.swift
//  Ora
//
//  Manages the confirmation flow for tool mutations
//

import Foundation
import os
import Combine

/// Manages confirmation flow and undo stack
@MainActor
final class ConfirmationManager: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = ConfirmationManager()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "Confirmation")
    
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    @Published private(set) var undoStack: [UndoAction] = []
    
    private var timeoutTask: Task<Void, Never>?
    private var countdownTimer: Timer?
    
    @Published private(set) var remainingSeconds: Int = 0
    
    /// Maximum undo stack size
    private let maxUndoStackSize = 10
    
    /// Callbacks
    var onConfirm: ((PendingConfirmation) -> Void)?
    var onDeny: ((PendingConfirmation) -> Void)?
    var onTimeout: ((PendingConfirmation) -> Void)?
    
    // MARK: - Initialization
    
    private init() {
        setupKeyboardShortcuts()
    }
    
    // MARK: - Public API
    
    /// Show a confirmation request
    func showConfirmation(_ confirmation: PendingConfirmation) {
        // Cancel any existing confirmation
        if pendingConfirmation != nil {
            cancelCurrentConfirmation(reason: .superseded)
        }
        
        pendingConfirmation = confirmation
        remainingSeconds = Int(confirmation.timeRemaining)
        
        startTimeout(for: confirmation)
        startCountdownTimer()
        
        logger.info("Showing confirmation: \(confirmation.toolName)")
    }
    
    /// Build confirmation from tool proposal
    func buildConfirmation(
        toolName: String,
        summary: String,
        args: [String: JSONValue]
    ) -> PendingConfirmation {
        let details = buildDetails(for: toolName, args: args)
        
        return PendingConfirmation(
            toolName: toolName,
            summary: summary,
            details: details,
            args: args
        )
    }
    
    /// Confirm the pending action
    func confirm() {
        guard let confirmation = pendingConfirmation else {
            logger.warning("No pending confirmation to confirm")
            return
        }
        
        logger.info("Confirmed: \(confirmation.toolName)")
        
        cancelTimeout()
        pendingConfirmation = nil
        
        onConfirm?(confirmation)
    }
    
    /// Deny the pending action
    func deny() {
        guard let confirmation = pendingConfirmation else {
            logger.warning("No pending confirmation to deny")
            return
        }
        
        logger.info("Denied: \(confirmation.toolName)")
        
        cancelTimeout()
        pendingConfirmation = nil
        
        onDeny?(confirmation)
    }
    
    /// Record an undo action after successful execution
    func recordUndoAction(_ action: UndoAction) {
        // Add to stack
        undoStack.insert(action, at: 0)
        
        // Trim stack if needed
        if undoStack.count > maxUndoStackSize {
            undoStack = Array(undoStack.prefix(maxUndoStackSize))
        }
        
        // Remove expired entries
        undoStack.removeAll { $0.isExpired }
        
        logger.debug("Recorded undo action: \(action.description)")
    }
    
    /// Get the most recent undoable action
    func lastUndoAction() -> UndoAction? {
        undoStack.first { !$0.isExpired }
    }
    
    /// Remove an undo action (after it's executed or expired)
    func removeUndoAction(_ action: UndoAction) {
        undoStack.removeAll { $0.id == action.id }
    }
    
    /// Check if there's a pending confirmation
    var hasPendingConfirmation: Bool {
        pendingConfirmation != nil
    }
    
    // MARK: - Private - Details Building
    
    private func buildDetails(for toolName: String, args: [String: JSONValue]) -> ConfirmationDetails {
        switch toolName {
        case "calendar.create_event":
            return buildCalendarCreateDetails(args)
            
        case "calendar.delete_event":
            return buildCalendarDeleteDetails(args)
            
        case "reminders.create":
            return buildReminderCreateDetails(args)
            
        case "reminders.complete":
            return buildReminderCompleteDetails(args)
            
        default:
            return buildGenericDetails(toolName, args)
        }
    }
    
    private func buildCalendarCreateDetails(_ args: [String: JSONValue]) -> ConfirmationDetails {
        var lines: [ConfirmationDetails.PreviewLine] = []
        
        if case .string(let title) = args["title"] {
            lines.append(.init(label: "Event", value: title, highlighted: true))
        }
        
        if case .string(let start) = args["start"] {
            let formatted = formatDateTime(start)
            lines.append(.init(label: "Start", value: formatted))
        }
        
        if case .string(let end) = args["end"] {
            let formatted = formatDateTime(end)
            lines.append(.init(label: "End", value: formatted))
        }
        
        if case .string(let location) = args["location"], !location.isEmpty {
            lines.append(.init(label: "Location", value: location))
        }
        
        if case .string(let calendar) = args["calendar_name"] {
            lines.append(.init(label: "Calendar", value: calendar))
        }
        
        return ConfirmationDetails(
            actionType: .create,
            targetDescription: "Calendar Event",
            previewLines: lines
        )
    }
    
    private func buildCalendarDeleteDetails(_ args: [String: JSONValue]) -> ConfirmationDetails {
        var lines: [ConfirmationDetails.PreviewLine] = []
        
        if case .string(let title) = args["event_title"] {
            lines.append(.init(label: "Event", value: title, highlighted: true))
        }
        
        if case .string(let eventId) = args["event_id"] {
            lines.append(.init(label: "ID", value: String(eventId.prefix(8)) + "..."))
        }
        
        return ConfirmationDetails(
            actionType: .delete,
            targetDescription: "Calendar Event",
            previewLines: lines
        )
    }
    
    private func buildReminderCreateDetails(_ args: [String: JSONValue]) -> ConfirmationDetails {
        var lines: [ConfirmationDetails.PreviewLine] = []
        
        if case .string(let title) = args["title"] {
            lines.append(.init(label: "Reminder", value: title, highlighted: true))
        }
        
        if case .string(let dueDate) = args["due_date"] {
            let formatted = formatDateTime(dueDate)
            lines.append(.init(label: "Due", value: formatted))
        }
        
        if case .string(let list) = args["list_name"] {
            lines.append(.init(label: "List", value: list))
        }
        
        return ConfirmationDetails(
            actionType: .create,
            targetDescription: "Reminder",
            previewLines: lines
        )
    }
    
    private func buildReminderCompleteDetails(_ args: [String: JSONValue]) -> ConfirmationDetails {
        var lines: [ConfirmationDetails.PreviewLine] = []
        
        if case .string(let title) = args["reminder_title"] {
            lines.append(.init(label: "Reminder", value: title, highlighted: true))
        }
        
        return ConfirmationDetails(
            actionType: .update,
            targetDescription: "Reminder",
            previewLines: lines
        )
    }
    
    private func buildGenericDetails(_ toolName: String, _ args: [String: JSONValue]) -> ConfirmationDetails {
        let lines = args.prefix(5).compactMap { key, value -> ConfirmationDetails.PreviewLine? in
            guard let stringValue = jsonValueToString(value) else { return nil }
            return .init(label: key.capitalized, value: stringValue)
        }
        
        let actionType: ConfirmationDetails.ActionType = 
            toolName.contains("delete") ? .delete :
            toolName.contains("create") ? .create : .update
        
        return ConfirmationDetails(
            actionType: actionType,
            targetDescription: toolName,
            previewLines: Array(lines)
        )
    }
    
    private func jsonValueToString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return b ? "Yes" : "No"
        default: return nil
        }
    }
    
    private func formatDateTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        guard let date = formatter.date(from: isoString) else {
            return isoString
        }
        
        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        displayFormatter.timeStyle = .short
        
        return displayFormatter.string(from: date)
    }
    
    // MARK: - Private - Timeout
    
    private func startTimeout(for confirmation: PendingConfirmation) {
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(confirmation.timeRemaining))
            
            guard !Task.isCancelled,
                  pendingConfirmation?.id == confirmation.id else {
                return
            }
            
            logger.info("Confirmation timed out: \(confirmation.toolName)")
            
            pendingConfirmation = nil
            stopCountdownTimer()
            
            onTimeout?(confirmation)
        }
    }
    
    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        stopCountdownTimer()
    }
    
    private func cancelCurrentConfirmation(reason: CancelReason) {
        guard let confirmation = pendingConfirmation else { return }
        
        logger.debug("Cancelling confirmation: \(reason)")
        
        cancelTimeout()
        pendingConfirmation = nil
    }
    
    private enum CancelReason {
        case superseded
        case userCancelled
    }
    
    // MARK: - Private - Countdown Timer
    
    private func startCountdownTimer() {
        stopCountdownTimer()
        
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self,
                      let confirmation = self.pendingConfirmation else {
                    return
                }
                
                self.remainingSeconds = Int(confirmation.timeRemaining)
            }
        }
    }
    
    private func stopCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        remainingSeconds = 0
    }
    
    // MARK: - Private - Keyboard
    
    private func setupKeyboardShortcuts() {
        // Listen for confirmation/deny via notification
        NotificationCenter.default.addObserver(
            forName: .proposalConfirmed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.confirm()
        }
        
        NotificationCenter.default.addObserver(
            forName: .proposalDenied,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.deny()
        }
    }
}
```

### 3.3 Enhanced Confirmation View

**File:** `Ora/Overlay/ConfirmationView.swift`

```swift
//
//  ConfirmationView.swift
//  Ora
//
//  Confirmation dialog for tool mutations
//

import SwiftUI

struct ConfirmationView: View {
    let confirmation: PendingConfirmation
    @ObservedObject var manager: ConfirmationManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(confirmation.details.actionType.rawValue) \(confirmation.details.targetDescription)")
                        .font(.headline)
                    
                    Text(confirmation.summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Countdown
                Text("\(manager.remainingSeconds)s")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            
            Divider()
            
            // Preview lines
            VStack(alignment: .leading, spacing: 8) {
                ForEach(confirmation.details.previewLines) { line in
                    HStack(alignment: .top) {
                        Text(line.label + ":")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        
                        Text(line.value)
                            .font(.caption)
                            .fontWeight(line.isHighlighted ? .semibold : .regular)
                            .foregroundColor(line.isHighlighted ? .primary : .secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            
            Divider()
            
            // Action buttons
            HStack {
                Button(action: { manager.deny() }) {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Cancel")
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.bordered)
                
                Button(action: { manager.confirm() }) {
                    HStack {
                        Image(systemName: "checkmark")
                        Text("Confirm")
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(buttonTint)
            }
            
            // Keyboard hint
            Text("Press Return to confirm, Escape to cancel")
                .font(.caption2)
                .foregroundColor(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(12)
        .shadow(radius: 8)
    }
    
    private var iconName: String {
        switch confirmation.details.actionType {
        case .create: return "plus.circle.fill"
        case .update: return "pencil.circle.fill"
        case .delete: return "trash.circle.fill"
        }
    }
    
    private var iconColor: Color {
        switch confirmation.details.actionType {
        case .create: return .green
        case .update: return .orange
        case .delete: return .red
        }
    }
    
    private var buttonTint: Color {
        switch confirmation.details.actionType {
        case .create: return .accentColor
        case .update: return .orange
        case .delete: return .red
        }
    }
}

// MARK: - Preview

#Preview {
    let confirmation = PendingConfirmation(
        toolName: "calendar.create_event",
        summary: "Create a meeting with John",
        details: ConfirmationDetails(
            actionType: .create,
            targetDescription: "Calendar Event",
            previewLines: [
                .init(label: "Event", value: "Meeting with John", highlighted: true),
                .init(label: "Start", value: "Dec 28, 2025 at 2:00 PM"),
                .init(label: "End", value: "Dec 28, 2025 at 3:00 PM"),
                .init(label: "Calendar", value: "Work")
            ]
        ),
        args: [:]
    )
    
    ConfirmationView(
        confirmation: confirmation,
        manager: .shared
    )
    .frame(width: 350)
    .padding()
}
```

### 3.4 Undo Support

**File:** `Ora/Orchestration/UndoSupport.swift`

```swift
//
//  UndoSupport.swift
//  Ora
//
//  Undo action generation for tool executions
//

import Foundation

/// Generates undo actions for tool executions
enum UndoSupport {
    
    /// Generate an undo action for a completed tool execution
    static func undoAction(
        for toolName: String,
        args: [String: JSONValue],
        result: ToolResult
    ) -> UndoAction? {
        switch toolName {
        case "calendar.create_event":
            return undoCalendarCreate(args: args, result: result)
            
        case "reminders.create":
            return undoReminderCreate(args: args, result: result)
            
        default:
            return nil
        }
    }
    
    private static func undoCalendarCreate(
        args: [String: JSONValue],
        result: ToolResult
    ) -> UndoAction? {
        // Extract event ID from result
        guard case .object(let resultDict) = result.json,
              case .string(let eventId) = resultDict["event_id"],
              case .string(let title) = args["title"] else {
            return nil
        }
        
        return UndoAction(
            toolName: "calendar.create_event",
            description: "Delete event: \(title)",
            undoToolName: "calendar.delete_event",
            undoArgs: [
                "event_id": .string(eventId),
                "event_title": .string(title)
            ]
        )
    }
    
    private static func undoReminderCreate(
        args: [String: JSONValue],
        result: ToolResult
    ) -> UndoAction? {
        // Extract reminder ID from result
        guard case .object(let resultDict) = result.json,
              case .string(let reminderId) = resultDict["reminder_id"],
              case .string(let title) = args["title"] else {
            return nil
        }
        
        return UndoAction(
            toolName: "reminders.create",
            description: "Delete reminder: \(title)",
            undoToolName: "reminders.delete",
            undoArgs: [
                "reminder_id": .string(reminderId),
                "reminder_title": .string(title)
            ]
        )
    }
}
```

---

## 4. Integration with Orchestrator

Update `ConversationOrchestrator` to use `ConfirmationManager`:

```swift
// In ConversationOrchestrator.swift

private func handleProposal(summary: String, tool: String, args: [String: JSONValue]) {
    let confirmation = ConfirmationManager.shared.buildConfirmation(
        toolName: tool,
        summary: summary,
        args: args
    )
    
    ConfirmationManager.shared.showConfirmation(confirmation)
    
    // Set up callbacks
    ConfirmationManager.shared.onConfirm = { [weak self] confirmed in
        self?.executeConfirmedTool(confirmed)
    }
    
    ConfirmationManager.shared.onDeny = { [weak self] _ in
        self?.handleDenial()
    }
    
    ConfirmationManager.shared.onTimeout = { [weak self] _ in
        self?.handleTimeout()
    }
    
    transition(to: .proposing(confirmation))
}

private func executeConfirmedTool(_ confirmation: PendingConfirmation) {
    // ... execute tool ...
    
    // Record undo action if applicable
    if let undoAction = UndoSupport.undoAction(
        for: confirmation.toolName,
        args: confirmation.args,
        result: result
    ) {
        ConfirmationManager.shared.recordUndoAction(undoAction)
    }
}
```

---

## 5. Directory Structure

```
Ora/
└── Orchestration/
    ├── ConfirmationState.swift
    ├── ConfirmationManager.swift
    └── UndoSupport.swift
    
└── Overlay/
    └── ConfirmationView.swift
```

---

## 6. Acceptance Criteria

### Confirmation UI

- [ ] **AC-1:** Confirmation dialog shows tool action type
- [ ] **AC-2:** Dialog shows human-readable summary
- [ ] **AC-3:** Dialog shows structured preview (event title, time, etc.)
- [ ] **AC-4:** Countdown timer visible
- [ ] **AC-5:** Confirm and Cancel buttons present

### User Interaction

- [ ] **AC-6:** Return key confirms action
- [ ] **AC-7:** Escape key denies action
- [ ] **AC-8:** Button clicks work correctly
- [ ] **AC-9:** Only one confirmation active at a time

### Timeout

- [ ] **AC-10:** 60-second default timeout
- [ ] **AC-11:** Countdown updates every second
- [ ] **AC-12:** Auto-cancel on timeout with message
- [ ] **AC-13:** Timeout task cancelled on user action

### Undo Support

- [ ] **AC-14:** Undo action recorded for create operations
- [ ] **AC-15:** Undo stack limited to 10 entries
- [ ] **AC-16:** Expired undo actions cleaned up
- [ ] **AC-17:** Undo action retrieval works

### Accessibility

- [ ] **AC-18:** VoiceOver announces "Confirm action required" when dialog appears
- [ ] **AC-19:** VoiceOver reads action type and summary
- [ ] **AC-20:** Countdown timer accessible (announces "X seconds remaining")
- [ ] **AC-21:** Buttons have clear accessibility labels ("Confirm [action]", "Cancel")
- [ ] **AC-22:** Focus automatically moves to confirmation dialog
- [ ] **AC-23:** Tab key navigates between Cancel and Confirm buttons
- [ ] **AC-24:** Reduced Motion preference disables countdown animation

---

## 7. Test Cases

```swift
// ConfirmationManagerTests.swift

import XCTest
@testable import Ora

@MainActor
final class ConfirmationManagerTests: XCTestCase {
    
    var manager: ConfirmationManager!
    
    override func setUp() {
        super.setUp()
        // Use shared instance (singleton)
        manager = ConfirmationManager.shared
    }
    
    override func tearDown() {
        // Clear any pending state
        if manager.hasPendingConfirmation {
            manager.deny()
        }
        super.tearDown()
    }
    
    // TC-1: Build calendar create confirmation
    func test_buildConfirmation_calendarCreate_hasCorrectDetails() {
        let confirmation = manager.buildConfirmation(
            toolName: "calendar.create_event",
            summary: "Create meeting",
            args: [
                "title": .string("Team Sync"),
                "start": .string("2025-12-28T14:00:00Z"),
                "end": .string("2025-12-28T15:00:00Z")
            ]
        )
        
        XCTAssertEqual(confirmation.details.actionType, .create)
        XCTAssertEqual(confirmation.details.targetDescription, "Calendar Event")
        XCTAssertFalse(confirmation.details.previewLines.isEmpty)
    }
    
    // TC-2: Show confirmation sets pending
    func test_showConfirmation_setsPending() {
        let confirmation = manager.buildConfirmation(
            toolName: "calendar.create_event",
            summary: "Test",
            args: [:]
        )
        
        manager.showConfirmation(confirmation)
        
        XCTAssertTrue(manager.hasPendingConfirmation)
        XCTAssertEqual(manager.pendingConfirmation?.id, confirmation.id)
        
        manager.deny() // Cleanup
    }
    
    // TC-3: Confirm clears pending
    func test_confirm_clearsPending() {
        let confirmation = manager.buildConfirmation(
            toolName: "calendar.create_event",
            summary: "Test",
            args: [:]
        )
        
        var confirmed = false
        manager.onConfirm = { _ in confirmed = true }
        
        manager.showConfirmation(confirmation)
        manager.confirm()
        
        XCTAssertFalse(manager.hasPendingConfirmation)
        XCTAssertTrue(confirmed)
    }
    
    // TC-4: Deny clears pending
    func test_deny_clearsPending() {
        let confirmation = manager.buildConfirmation(
            toolName: "calendar.create_event",
            summary: "Test",
            args: [:]
        )
        
        var denied = false
        manager.onDeny = { _ in denied = true }
        
        manager.showConfirmation(confirmation)
        manager.deny()
        
        XCTAssertFalse(manager.hasPendingConfirmation)
        XCTAssertTrue(denied)
    }
    
    // TC-5: Undo action recording
    func test_recordUndoAction_addsToStack() {
        let action = UndoAction(
            toolName: "calendar.create_event",
            description: "Delete event",
            undoToolName: "calendar.delete_event",
            undoArgs: ["event_id": .string("123")]
        )
        
        let initialCount = manager.undoStack.count
        manager.recordUndoAction(action)
        
        XCTAssertEqual(manager.undoStack.count, initialCount + 1)
        XCTAssertEqual(manager.undoStack.first?.id, action.id)
        
        // Cleanup
        manager.removeUndoAction(action)
    }
    
    // TC-6: Time remaining calculation
    func test_confirmation_timeRemaining_decreases() async {
        let confirmation = PendingConfirmation(
            toolName: "test",
            summary: "Test",
            details: ConfirmationDetails(
                actionType: .create,
                targetDescription: "Test",
                previewLines: []
            ),
            args: [:],
            timeout: 60
        )
        
        let initial = confirmation.timeRemaining
        try? await Task.sleep(for: .milliseconds(100))
        let after = confirmation.timeRemaining
        
        XCTAssertLessThan(after, initial)
    }
}
```

---

## 8. Implementation Checklist

- [ ] Create `ConfirmationState.swift`
- [ ] Create `ConfirmationManager.swift`
- [ ] Create `ConfirmationView.swift`
- [ ] Create `UndoSupport.swift`
- [ ] Implement detail builders for each tool type
- [ ] Implement countdown timer
- [ ] Implement timeout handling
- [ ] Add keyboard shortcuts (Return/Escape)
- [ ] Integrate with ConversationOrchestrator
- [ ] Test confirmation flow end-to-end
- [ ] Test timeout behavior
- [ ] Test undo recording
