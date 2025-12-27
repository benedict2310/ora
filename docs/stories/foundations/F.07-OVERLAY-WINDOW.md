# F.07 - Overlay Window

**Epic:** Foundations
**Status:** Not Started
**Priority:** P0 (Critical Path)
**Estimated Effort:** 2 days
**Dependencies:** F.01 (App Shell), F.05 (Global Hotkey)
**Target:** macOS 26 (Tahoe)
**Design Reference:** [Liquid Glass UI Guide](../../references/liquid-glass-ui.md)

---

## 1. Objective

Create the floating overlay window that appears when the user activates Ora via hotkey. This window displays the conversation, transcription progress, and tool execution status.

### Overlay Behavior

```
┌─────────────────────────────────────────────────────────────┐
│  Hotkey Pressed                                             │
│       │                                                     │
│       ▼                                                     │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Overlay Window Appears                  │   │
│  │  - Positioned near cursor or center of screen       │   │
│  │  - Floating above all windows                       │   │
│  │  - Shows listening indicator                        │   │
│  └─────────────────────────────────────────────────────┘   │
│       │                                                     │
│       ▼  (User speaks, partials stream)                    │
│       │                                                     │
│       ▼  (Hotkey released)                                 │
│       │                                                     │
│       ▼  (LLM processes, response streams)                 │
│       │                                                     │
│       ▼  (TTS plays, then auto-dismiss after delay)        │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Architecture

### Window Properties

| Property | Value | Reason |
|:---------|:------|:-------|
| Style | Borderless, floating | Clean appearance |
| Level | `NSWindow.Level.floating` | Above other windows |
| Behavior | Non-activating | Doesn't steal focus |
| Background | Liquid Glass | macOS 26 Tahoe design |
| Corner radius | 16pt | Modern macOS style |
| Shadow | Yes | Visual separation |

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                   OverlayWindowController                    │
│                       (@MainActor)                           │
├─────────────────────────────────────────────────────────────┤
│  - NSPanel (floating, non-activating)                       │
│  - Position management                                      │
│  - Show/hide animations                                     │
│  - Auto-dismiss logic                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      OverlayView                             │
│                       (SwiftUI)                              │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Status Indicator (listening/thinking/speaking)      │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Transcript Area                                     │   │
│  │  - User message (partial → final)                   │   │
│  │  - Assistant response (streaming)                   │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Tool Execution (if any)                            │   │
│  │  - Proposal with confirm/deny                       │   │
│  │  - Execution status                                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Implementation

### 3.1 Overlay State

**File:** `Ora/Overlay/OverlayState.swift`

```swift
//
//  OverlayState.swift
//  Ora
//
//  State management for the overlay window
//

import Foundation

/// Current state of the overlay
enum OverlayMode: Equatable, Sendable {
    case hidden
    case listening
    case thinking
    case responding
    case proposing(ToolProposal)
    case executing
    case completed
    case error(String)
}

/// Tool proposal requiring user confirmation
struct ToolProposal: Equatable, Sendable {
    let toolName: String
    let summary: String
    let details: String?
}

/// A message in the conversation
struct OverlayMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: MessageRole
    var content: String
    var isPartial: Bool
    let timestamp: Date
    
    enum MessageRole: Sendable {
        case user
        case assistant
    }
    
    init(role: MessageRole, content: String, isPartial: Bool = false) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isPartial = isPartial
        self.timestamp = Date()
    }
}

/// Observable state for the overlay
@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var mode: OverlayMode = .hidden
    @Published var messages: [OverlayMessage] = []
    @Published var currentProposal: ToolProposal?
    
    /// Add a user message (from ASR)
    func addUserMessage(_ text: String, isPartial: Bool) {
        if let lastIndex = messages.lastIndex(where: { $0.role == .user && $0.isPartial }) {
            // Update existing partial
            messages[lastIndex].content = text
            messages[lastIndex].isPartial = isPartial
        } else {
            // Add new message
            messages.append(OverlayMessage(role: .user, content: text, isPartial: isPartial))
        }
    }
    
    /// Add an assistant message (from LLM)
    func addAssistantMessage(_ text: String, isPartial: Bool) {
        if let lastIndex = messages.lastIndex(where: { $0.role == .assistant && $0.isPartial }) {
            // Update existing partial
            messages[lastIndex].content = text
            messages[lastIndex].isPartial = isPartial
        } else {
            // Add new message
            messages.append(OverlayMessage(role: .assistant, content: text, isPartial: isPartial))
        }
    }
    
    /// Show a tool proposal
    func showProposal(_ proposal: ToolProposal) {
        currentProposal = proposal
        mode = .proposing(proposal)
    }
    
    /// Clear conversation for new session
    func reset() {
        messages.removeAll()
        currentProposal = nil
        mode = .hidden
    }
}
```

### 3.2 Overlay Window Controller

**File:** `Ora/Overlay/OverlayWindowController.swift`

```swift
//
//  OverlayWindowController.swift
//  Ora
//
//  Manages the floating overlay window
//

import AppKit
import SwiftUI
import os

@MainActor
final class OverlayWindowController {
    
    // MARK: - Singleton
    
    static let shared = OverlayWindowController()
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "com.ora.app", category: "OverlayWindow")
    private var panel: NSPanel?
    private let viewModel = OverlayViewModel()
    
    private var autoDismissTask: Task<Void, Never>?
    private let autoDismissDelay: TimeInterval = 3.0
    
    /// Current overlay mode
    var mode: OverlayMode {
        get { viewModel.mode }
        set { viewModel.mode = newValue }
    }
    
    /// View model for external updates
    var model: OverlayViewModel {
        viewModel
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public API
    
    /// Show the overlay window
    func show() {
        if panel == nil {
            createPanel()
        }
        
        guard let panel = panel else { return }
        
        // Cancel any pending auto-dismiss
        autoDismissTask?.cancel()
        autoDismissTask = nil
        
        // Position and show
        positionPanel()
        panel.orderFront(nil)
        
        // Animate in
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        
        logger.debug("Overlay shown")
    }
    
    /// Hide the overlay window
    func hide(animated: Bool = true) {
        guard let panel = panel else { return }
        
        autoDismissTask?.cancel()
        autoDismissTask = nil
        
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                self.viewModel.reset()
            }
        } else {
            panel.orderOut(nil)
            viewModel.reset()
        }
        
        logger.debug("Overlay hidden")
    }
    
    /// Schedule auto-dismiss after response completes
    func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(autoDismissDelay))
            guard !Task.isCancelled else { return }
            hide()
        }
    }
    
    /// Cancel scheduled auto-dismiss
    func cancelAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
    
    // MARK: - Private
    
    private func createPanel() {
        let contentView = OverlayView()
            .environmentObject(viewModel)
        
        let hostingView = NSHostingView(rootView: contentView)
        
        // Create floating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        
        // Rounded corners
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 12
        panel.contentView?.layer?.masksToBounds = true
        
        self.panel = panel
        logger.debug("Overlay panel created")
    }
    
    private func positionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        
        // Position in upper-center of screen
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        
        let x = screenFrame.midX - (panelSize.width / 2)
        let y = screenFrame.maxY - panelSize.height - 100 // 100pt from top
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

### 3.3 Overlay View

**File:** `Ora/Overlay/OverlayView.swift`

```swift
//
//  OverlayView.swift
//  Ora
//
//  Main overlay content view
//

import SwiftUI

struct OverlayView: View {
    @EnvironmentObject var viewModel: OverlayViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            // Status indicator
            StatusIndicatorView(mode: viewModel.mode)
                .padding(.top, 16)
                .padding(.bottom, 12)
            
            Divider()
            
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    // Scroll to bottom
                    if let lastMessage = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Tool proposal (if any)
            if case .proposing(let proposal) = viewModel.mode {
                Divider()
                ToolProposalView(proposal: proposal)
            }
        }
        .frame(width: 400, height: 300)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Status Indicator

struct StatusIndicatorView: View {
    let mode: OverlayMode
    
    var body: some View {
        HStack(spacing: 8) {
            // Animated indicator
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
                .scaleEffect(shouldPulse ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.5).repeatForever(), value: shouldPulse)
            
            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var indicatorColor: Color {
        switch mode {
        case .listening: return .blue
        case .thinking: return .orange
        case .responding, .executing: return .green
        case .proposing: return .yellow
        case .error: return .red
        default: return .secondary
        }
    }
    
    private var shouldPulse: Bool {
        switch mode {
        case .listening, .thinking, .executing: return true
        default: return false
        }
    }
    
    private var statusText: String {
        switch mode {
        case .hidden: return ""
        case .listening: return "Listening..."
        case .thinking: return "Thinking..."
        case .responding: return "Responding..."
        case .proposing: return "Confirm action"
        case .executing: return "Executing..."
        case .completed: return "Done"
        case .error(let message): return "Error: \(message)"
        }
    }
}

// MARK: - Message Bubble

struct MessageBubbleView: View {
    let message: OverlayMessage
    
    var body: some View {
        HStack {
            if message.role == .assistant {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: message.role == .user ? .leading : .trailing, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .cornerRadius(16)
                    .opacity(message.isPartial ? 0.8 : 1.0)
                
                if message.isPartial {
                    Text("Listening...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            if message.role == .user {
                Spacer(minLength: 40)
            }
        }
    }
    
    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
    }
    
    private var textColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - Tool Proposal

struct ToolProposalView: View {
    let proposal: ToolProposal
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                Text("Confirm Action")
                    .font(.headline)
            }
            
            Text(proposal.summary)
                .font(.body)
            
            if let details = proposal.details {
                Text(details)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Button("Cancel") {
                    // Post deny notification
                    NotificationCenter.default.post(name: .proposalDenied, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Confirm") {
                    // Post confirm notification
                    NotificationCenter.default.post(name: .proposalConfirmed, object: nil)
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .padding()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let proposalConfirmed = Notification.Name("proposalConfirmed")
    static let proposalDenied = Notification.Name("proposalDenied")
}
```

### 3.4 Integration with Hotkey

**Update:** `Ora/AppDelegate.swift`

```swift
private func onHotkeyPress() {
    logger.debug("Hotkey pressed - start PTT")
    statusBarController?.setState(.listening)
    
    // Show overlay
    OverlayWindowController.shared.mode = .listening
    OverlayWindowController.shared.show()
}

private func onHotkeyRelease() {
    logger.debug("Hotkey released - end PTT")
    statusBarController?.setState(.thinking)
    
    // Update overlay mode
    OverlayWindowController.shared.mode = .thinking
}
```

---

## 4. Directory Structure

```
Ora/
└── Overlay/
    ├── OverlayState.swift
    ├── OverlayWindowController.swift
    └── OverlayView.swift
```

---

## 5. Acceptance Criteria

### Window Behavior

- [ ] **AC-1:** Overlay appears when hotkey pressed
- [ ] **AC-2:** Overlay floats above all windows
- [ ] **AC-3:** Overlay doesn't steal focus
- [ ] **AC-4:** Overlay can be dragged by background
- [ ] **AC-5:** Overlay auto-dismisses after response (configurable delay)

### Visual Design

- [ ] **AC-6:** Rounded corners (12pt)
- [ ] **AC-7:** Vibrancy/blur background
- [ ] **AC-8:** Shadow for visual separation
- [ ] **AC-9:** Smooth fade in/out animations

### Content

- [ ] **AC-10:** Status indicator shows current mode
- [ ] **AC-11:** User messages displayed with partial indicator
- [ ] **AC-12:** Assistant messages stream in
- [ ] **AC-13:** Tool proposals shown with confirm/deny buttons

### State Management

- [ ] **AC-14:** Mode transitions correctly (listening → thinking → responding)
- [ ] **AC-15:** Messages cleared on reset
- [ ] **AC-16:** Confirmation timeout cancels proposal (1 minute)

### Keyboard Navigation

- [ ] **AC-17:** Tab key navigates between focusable elements
- [ ] **AC-18:** Return key confirms actions
- [ ] **AC-19:** Escape key cancels/dismisses overlay
- [ ] **AC-20:** Arrow keys scroll message list when focused

### Accessibility

- [ ] **AC-21:** VoiceOver announces status changes ("Listening", "Thinking", etc.)
- [ ] **AC-22:** All interactive elements have accessibility labels
- [ ] **AC-23:** Message bubbles readable by VoiceOver with role context
- [ ] **AC-24:** Reduced Motion preference respected (no pulse animations)
- [ ] **AC-25:** Minimum contrast ratio of 4.5:1 for all text
- [ ] **AC-26:** Focus indicators visible on all interactive elements

---

## 6. Test Cases

```swift
// OverlayViewModelTests.swift

import XCTest
@testable import Ora

@MainActor
final class OverlayViewModelTests: XCTestCase {
    
    // TC-1: Initial state
    func test_initialMode_isHidden() {
        let viewModel = OverlayViewModel()
        XCTAssertEqual(viewModel.mode, .hidden)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }
    
    // TC-2: Add user message
    func test_addUserMessage_addsMessage() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Hello", isPartial: false)
        
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].role, .user)
        XCTAssertEqual(viewModel.messages[0].content, "Hello")
    }
    
    // TC-3: Update partial message
    func test_addUserMessage_updatesPartial() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Hel", isPartial: true)
        viewModel.addUserMessage("Hello", isPartial: true)
        viewModel.addUserMessage("Hello world", isPartial: false)
        
        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages[0].content, "Hello world")
        XCTAssertFalse(viewModel.messages[0].isPartial)
    }
    
    // TC-4: Reset clears state
    func test_reset_clearsAll() {
        let viewModel = OverlayViewModel()
        viewModel.addUserMessage("Test", isPartial: false)
        viewModel.mode = .listening
        
        viewModel.reset()
        
        XCTAssertEqual(viewModel.mode, .hidden)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }
}
```

---

## 7. Implementation Checklist

- [ ] Create `OverlayState.swift`
- [ ] Create `OverlayWindowController.swift`
- [ ] Create `OverlayView.swift`
- [ ] Implement status indicator animation
- [ ] Implement message bubbles
- [ ] Implement tool proposal UI
- [ ] Add show/hide animations
- [ ] Add auto-dismiss logic
- [ ] Integrate with hotkey events
- [ ] Test window positioning
- [ ] Test on multiple monitors
