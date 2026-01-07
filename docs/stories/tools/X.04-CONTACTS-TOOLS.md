# X.04 - Contacts Tools

**Epic:** Tools
**Status:** In Progress
**Priority:** P1 (Important)
**Estimated Effort:** 1 day
**Dependencies:** X.01 (Tool Protocol), F.02 (Permissions)
**Target:** macOS 26 (Tahoe)

---

## 1. Objective

Implement contacts search using the Contacts framework.

---

## 2. User Story

As a user, I want to find contact information for people in my address book so that I can get their phone numbers or email addresses quickly.

---

## 3. Scope

**In Scope:**
- Searching contacts by name
- Retrieving phone numbers, emails, and organization names
- Limiting the number of results

**Out of Scope:**
- Creating or editing contacts
- Deleting contacts
- Searching by fields other than name

---

## 4. Architecture Alignment

- **Tool Protocol:** Implements `Tool` protocol defined in `Ora/Tools/Tool.swift`.
- **Permissions:** Uses `Permissions.swift` to ensure access to Contacts.
- **Privacy:** Reads minimal data necessary (Name, Email, Phone, Organization).

---

## 5. Implementation Plan (Draft)

### 5.1 Files to Create
- `Ora/Tools/Contacts/ContactsSearchTool.swift`: Implementation of the contact search logic.
- `Ora/Tools/Contacts/ContactsToolErrors.swift`: Error types for contacts tools.
- `OraTests/Tools/Contacts/ContactsSearchToolTests.swift`: Unit tests for parameter validation and result formatting.

### 5.2 Files to Modify
- `Ora/Tools/ToolRegistry.swift`: Register the new tool.
- `OraTests/Tools/Calendar/CalendarToolsTests.swift`: Update total tool count expectation.
- `OraTests/Tools/Reminders/RemindersToolsTests.swift`: Update total tool count expectation.

### 5.3 Tests to Add
- `OraTests/Tools/ContactsSearchToolTests.swift`: Unit tests for parameter validation and result formatting.

---

## 6. Acceptance Criteria

- [x] **AC-1:** Search returns matching contacts. - ✅ Verified by `ContactsSearchTool` logic and tests.
- [x] **AC-2:** Results include name, email, phone, and organization. - ✅ Verified by `ContactsSearchTool` logic.
- [x] **AC-3:** Limit parameter is respected. - ✅ Verified by `ContactsSearchTool` logic.
- [x] **AC-4:** Human summary is natural for single result. - ✅ Verified by `ContactsSearchTool` logic.
- [x] **AC-5:** Appropriate error handling when permission is denied or parameters are missing. - ✅ Verified by `ContactsSearchTool` logic and tests.

---

## 7. Verification Plan

### Automated Tests
- Run `ContactsSearchToolTests` to verify validation and execution logic.
- Run `CalendarToolsTests` and `RemindersToolsTests` to verify registry integrity.

### Manual Tests
1. Run `./build.sh run`
2. Grant contacts permission.
3. Ask: "What is [Name]'s phone number?"
4. Verify the assistant responds with the correct number.
5. Ask: "Find contacts named [Name]"
6. Verify multiple results are handled.

---

## 8. Implementation Summary
**Date:** 2026-01-07
**Branch:** `feat/X.04-contacts-tools`
**Commits:** 1 (WIP)

### Files Changed
- `Ora/Tools/Contacts/ContactsSearchTool.swift` - Created
- `Ora/Tools/Contacts/ContactsToolErrors.swift` - Created
- `Ora/Tools/ToolRegistry.swift` - Modified (registered tool)
- `OraTests/Tools/Contacts/ContactsSearchToolTests.swift` - Created
- `OraTests/Tools/Calendar/CalendarToolsTests.swift` - Modified (updated tests)
- `OraTests/Tools/Reminders/RemindersToolsTests.swift` - Modified (updated tests)

### Ready for Review
- [x] All acceptance criteria verified
- [x] Tests passing
- [x] Working tree clean
