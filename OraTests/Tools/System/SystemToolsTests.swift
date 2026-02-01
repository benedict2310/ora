//
//  SystemToolsTests.swift
//  OraTests
//
//  Tests for system tools
//

import XCTest
@testable import Ora

final class SystemToolsTests: XCTestCase {
    
    // MARK: - SystemOpenAppTool Tests
    
    func test_openAppTool_hasCorrectMetadata() async throws {
        let tool = SystemOpenAppTool()
        XCTAssertEqual(tool.name, "system.open_app")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_openAppTool_validateRequiresAtLeastOneParameter() async throws {
        let tool = SystemOpenAppTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("bundle_id or app_name"))
        }
        
        // Empty string values should fail
        XCTAssertThrowsError(try tool.validate(args: ["bundle_id": .string(""), "app_name": .string("")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("bundle_id or app_name"))
        }
        
        // Valid bundle_id should pass
        XCTAssertNoThrow(try tool.validate(args: ["bundle_id": .string("com.apple.Safari")]))
        
        // Valid app_name should pass
        XCTAssertNoThrow(try tool.validate(args: ["app_name": .string("Safari")]))
    }
    
    // MARK: - SystemOpenURLTool Tests
    
    func test_openURLTool_hasCorrectMetadata() async throws {
        let tool = SystemOpenURLTool()
        XCTAssertEqual(tool.name, "system.open_url")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_openURLTool_validateRequiresURL() async throws {
        let tool = SystemOpenURLTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("url"))
        }
        
        // Empty string should fail
        XCTAssertThrowsError(try tool.validate(args: ["url": .string("")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("url"))
        }
        
        // Valid URL should pass
        XCTAssertNoThrow(try tool.validate(args: ["url": .string("https://example.com")]))
    }
    
    // MARK: - SystemOpenPathTool Tests
    
    func test_openPathTool_hasCorrectMetadata() async throws {
        let tool = SystemOpenPathTool()
        XCTAssertEqual(tool.name, "system.open_path")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_openPathTool_validateRequiresPath() async throws {
        let tool = SystemOpenPathTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("path"))
        }
        
        // Valid path should pass
        XCTAssertNoThrow(try tool.validate(args: ["path": .string("/Users")]))
    }
    
    func test_openPathTool_throwsNotFoundForInvalidPath() async throws {
        let tool = SystemOpenPathTool()
        
        do {
            _ = try await tool.execute(args: ["path": .string("/nonexistent/path/12345")])
            XCTFail("Should have thrown an error")
        } catch let error as SystemToolError {
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - SystemRevealInFinderTool Tests
    
    func test_revealInFinderTool_hasCorrectMetadata() async throws {
        let tool = SystemRevealInFinderTool()
        XCTAssertEqual(tool.name, "system.reveal_in_finder")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_revealInFinderTool_throwsNotFoundForInvalidPath() async throws {
        let tool = SystemRevealInFinderTool()
        
        do {
            _ = try await tool.execute(args: ["path": .string("/nonexistent/file/12345.txt")])
            XCTFail("Should have thrown an error")
        } catch let error as SystemToolError {
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
    
    // MARK: - SystemOpenFolderSpecialTool Tests
    
    func test_openFolderSpecialTool_hasCorrectMetadata() async throws {
        let tool = SystemOpenFolderSpecialTool()
        XCTAssertEqual(tool.name, "system.open_folder_special")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_openFolderSpecialTool_validateRequiresFolderName() async throws {
        let tool = SystemOpenFolderSpecialTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("folder"))
        }
        
        // Invalid folder name should fail
        XCTAssertThrowsError(try tool.validate(args: ["folder": .string("invalid")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("downloads, desktop"))
        }
        
        // Valid folder names should pass
        XCTAssertNoThrow(try tool.validate(args: ["folder": .string("downloads")]))
        XCTAssertNoThrow(try tool.validate(args: ["folder": .string("desktop")]))
        XCTAssertNoThrow(try tool.validate(args: ["folder": .string("documents")]))
        XCTAssertNoThrow(try tool.validate(args: ["folder": .string("applications")]))
        XCTAssertNoThrow(try tool.validate(args: ["folder": .string("home")]))
    }
    
    // MARK: - SystemOpenSettingsTool Tests
    
    func test_openSettingsTool_hasCorrectMetadata() async throws {
        let tool = SystemOpenSettingsTool()
        XCTAssertEqual(tool.name, "system.open_settings")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_openSettingsTool_validateAllowsEmptyPane() async throws {
        let tool = SystemOpenSettingsTool()
        
        // No pane is valid
        XCTAssertNoThrow(try tool.validate(args: [:]))
        
        // Various panes are valid
        XCTAssertNoThrow(try tool.validate(args: ["pane": .string("wifi")]))
        XCTAssertNoThrow(try tool.validate(args: ["pane": .string("bluetooth")]))
        XCTAssertNoThrow(try tool.validate(args: ["pane": .string("privacy")]))
    }
    
    // MARK: - SystemSearchFilesTool Tests
    
    func test_searchFilesTool_hasCorrectMetadata() async throws {
        let tool = SystemSearchFilesTool()
        XCTAssertEqual(tool.name, "system.search_files")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_searchFilesTool_validateRequiresQuery() async throws {
        let tool = SystemSearchFilesTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("query"))
        }
        
        // Valid query should pass
        XCTAssertNoThrow(try tool.validate(args: ["query": .string("test")]))
    }
    
    // MARK: - SystemSearchAppsTool Tests
    
    func test_searchAppsTool_hasCorrectMetadata() async throws {
        let tool = SystemSearchAppsTool()
        XCTAssertEqual(tool.name, "system.search_apps")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_searchAppsTool_validateRequiresQuery() async throws {
        let tool = SystemSearchAppsTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("query"))
        }
        
        // Valid query should pass
        XCTAssertNoThrow(try tool.validate(args: ["query": .string("Safari")]))
    }
    
    func test_searchAppsTool_findsSystemApps() async throws {
        let tool = SystemSearchAppsTool()
        
        // Search for Safari which should exist on all macOS systems
        let result = try await tool.execute(args: ["query": .string("Safari"), "limit": .number(5)])
        
        XCTAssertTrue(result.humanSummary.contains("Found") || result.humanSummary.contains("app"))
        
        // Check the JSON structure
        if case .object(let dict) = result.json,
           case .array(let results) = dict["results"] {
            // Safari should be found
            XCTAssertGreaterThan(results.count, 0)
            
            // Check structure of first result
            if case .object(let firstResult) = results[0] {
                XCTAssertNotNil(firstResult["name"])
                XCTAssertNotNil(firstResult["bundle_id"])
                XCTAssertNotNil(firstResult["path"])
            }
        }
    }
    
    // MARK: - Fuzzy App Search Tests

    func test_searchApps_fuzzyFallback_findsTypo() async throws {
        // "Safar" is not a substring of "Safari" but is close enough for fuzzy
        // However "Safar" IS a substring of "Safari", so use a typo that isn't a substring
        let apps: [(name: String, bundleId: String?, path: String)] = [
            (name: "Safari", bundleId: "com.apple.Safari", path: "/Applications/Safari.app"),
            (name: "Notes", bundleId: "com.apple.Notes", path: "/Applications/Notes.app"),
            (name: "Calendar", bundleId: "com.apple.iCal", path: "/Applications/Calendar.app")
        ]
        let results = SystemSearchAppsTool.fuzzyMatch(query: "Saffari", apps: apps)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Safari")
        XCTAssertNotNil(results.first?.matchScore)
        if let score = results.first?.matchScore {
            XCTAssertGreaterThanOrEqual(score, SystemSearchAppsTool.fuzzyThreshold)
        }
    }

    func test_searchApps_fuzzyFallback_respectsThreshold() {
        let apps: [(name: String, bundleId: String?, path: String)] = [
            (name: "Safari", bundleId: nil, path: "/Applications/Safari.app"),
            (name: "Keynote", bundleId: nil, path: "/Applications/Keynote.app")
        ]
        // "xyzgarbage" is nothing like any app name
        let results = SystemSearchAppsTool.fuzzyMatch(query: "xyzgarbage", apps: apps)
        XCTAssertTrue(results.isEmpty)
    }

    func test_searchApps_fuzzyFallback_sortedByScore() {
        let apps: [(name: String, bundleId: String?, path: String)] = [
            (name: "Keynote", bundleId: nil, path: "/Applications/Keynote.app"),
            (name: "Keychain Access", bundleId: nil, path: "/Applications/Keychain Access.app"),
            (name: "Calendar", bundleId: nil, path: "/Applications/Calendar.app")
        ]
        // "Keenote" is closer to "Keynote" than "Keychain Access"
        let results = SystemSearchAppsTool.fuzzyMatch(query: "Keenote", apps: apps)
        if results.count >= 2 {
            let keynoteScore = StringSimilarity.jaroWinkler("Keenote", "Keynote")
            let keychainScore = StringSimilarity.jaroWinkler("Keenote", "Keychain Access")
            XCTAssertGreaterThan(keynoteScore, keychainScore)
            XCTAssertEqual(results.first?.name, "Keynote")
        } else if results.count == 1 {
            XCTAssertEqual(results.first?.name, "Keynote")
        }
    }

    func test_searchApps_fuzzyFallback_respectsLimit() {
        let apps: [(name: String, bundleId: String?, path: String)] = [
            (name: "App1", bundleId: nil, path: "/Applications/App1.app"),
            (name: "App2", bundleId: nil, path: "/Applications/App2.app"),
            (name: "App3", bundleId: nil, path: "/Applications/App3.app"),
            (name: "App4", bundleId: nil, path: "/Applications/App4.app")
        ]
        let results = SystemSearchAppsTool.fuzzyMatch(query: "App1", apps: apps, limit: 2)
        XCTAssertLessThanOrEqual(results.count, 2)
    }

    func test_searchApps_fuzzyThreshold_isPointEight() {
        XCTAssertEqual(SystemSearchAppsTool.fuzzyThreshold, 0.80)
    }

    func test_searchAppsTool_appToJSON_includesMatchScore() throws {
        let match = SystemSearchAppsTool.AppMatch(
            name: "Safari",
            bundleId: "com.apple.Safari",
            path: "/Applications/Safari.app",
            matchScore: 0.923
        )
        let json = SystemSearchAppsTool.appToJSON(match)
        if case .object(let dict) = json {
            let score = try XCTUnwrap(dict["match_score"]?.numberValue)
            XCTAssertEqual(score, 0.92, accuracy: 0.001)
        } else {
            XCTFail("Expected app JSON object")
        }
    }

    func test_searchAppsTool_appToJSON_omitsMatchScoreWhenNil() {
        let match = SystemSearchAppsTool.AppMatch(
            name: "Safari",
            bundleId: "com.apple.Safari",
            path: "/Applications/Safari.app",
            matchScore: nil
        )
        let json = SystemSearchAppsTool.appToJSON(match)
        if case .object(let dict) = json {
            XCTAssertNil(dict["match_score"])
        } else {
            XCTFail("Expected app JSON object")
        }
    }

    // MARK: - SystemRunShortcutTool Tests
    
    func test_runShortcutTool_hasCorrectMetadata() async throws {
        let tool = SystemRunShortcutTool()
        XCTAssertEqual(tool.name, "system.run_shortcut")
        XCTAssertEqual(tool.kind, .mutate)
        XCTAssertTrue(tool.requiresConfirmation)
    }
    
    func test_runShortcutTool_validateRequiresName() async throws {
        let tool = SystemRunShortcutTool()
        
        // Empty args should fail
        XCTAssertThrowsError(try tool.validate(args: [:])) { error in
            XCTAssertTrue(error.localizedDescription.contains("name"))
        }
        
        // Valid name should pass
        XCTAssertNoThrow(try tool.validate(args: ["name": .string("Test Shortcut")]))
    }
    
    // MARK: - SystemListShortcutsTool Tests
    
    func test_listShortcutsTool_hasCorrectMetadata() async throws {
        let tool = SystemListShortcutsTool()
        XCTAssertEqual(tool.name, "system.list_shortcuts")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_listShortcutsTool_noValidationRequired() async throws {
        let tool = SystemListShortcutsTool()
        
        // No args required
        XCTAssertNoThrow(try tool.validate(args: [:]))
    }
    
    // MARK: - SystemListAppsTool Tests
    
    func test_listAppsTool_hasCorrectMetadata() async throws {
        let tool = SystemListAppsTool()
        XCTAssertEqual(tool.name, "system.list_apps")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertFalse(tool.requiresConfirmation)
    }
    
    func test_listAppsTool_validateAcceptsValidCategories() async throws {
        let tool = SystemListAppsTool()
        
        // No category is valid (defaults to "all")
        XCTAssertNoThrow(try tool.validate(args: [:]))
        
        // All valid categories should pass
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("user")]))
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("system")]))
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("utility")]))
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("all")]))
        
        // Case insensitive
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("USER")]))
        XCTAssertNoThrow(try tool.validate(args: ["category": .string("All")]))
    }
    
    func test_listAppsTool_validateRejectsInvalidCategory() async throws {
        let tool = SystemListAppsTool()
        
        XCTAssertThrowsError(try tool.validate(args: ["category": .string("invalid")])) { error in
            XCTAssertTrue(error.localizedDescription.contains("user, system, utility, all"))
        }
    }
    
    func test_listAppsTool_returnsAllCategories() async throws {
        let tool = SystemListAppsTool()
        let result = try await tool.execute(args: [:])
        
        // Check the JSON structure
        if case .object(let dict) = result.json {
            // Should have all three categories
            XCTAssertNotNil(dict["user"], "Should have user category")
            XCTAssertNotNil(dict["system"], "Should have system category")
            XCTAssertNotNil(dict["utility"], "Should have utility category")
            XCTAssertNotNil(dict["total"], "Should have total count")
            
            // Total should be a number
            if case .number(let total) = dict["total"] {
                XCTAssertGreaterThan(total, 0, "Should find at least some apps")
            } else {
                XCTFail("Total should be a number")
            }
        } else {
            XCTFail("Result should be an object")
        }
        
        // Summary should mention all categories
        XCTAssertTrue(result.humanSummary.contains("Found"))
        XCTAssertTrue(result.humanSummary.contains("user"))
        XCTAssertTrue(result.humanSummary.contains("system"))
        XCTAssertTrue(result.humanSummary.contains("utilities"))
    }
    
    func test_listAppsTool_filterByCategory() async throws {
        let tool = SystemListAppsTool()
        
        // Filter by user
        let userResult = try await tool.execute(args: ["category": .string("user")])
        if case .object(let dict) = userResult.json {
            XCTAssertNotNil(dict["user"], "Should have user category")
            XCTAssertNil(dict["system"], "Should not have system category when filtered")
            XCTAssertNil(dict["utility"], "Should not have utility category when filtered")
        }
        XCTAssertTrue(userResult.humanSummary.contains("user apps"))
        
        // Filter by system
        let systemResult = try await tool.execute(args: ["category": .string("system")])
        if case .object(let dict) = systemResult.json {
            XCTAssertNotNil(dict["system"], "Should have system category")
            XCTAssertNil(dict["user"], "Should not have user category when filtered")
            XCTAssertNil(dict["utility"], "Should not have utility category when filtered")
        }
        XCTAssertTrue(systemResult.humanSummary.contains("system apps"))
        
        // Filter by utility
        let utilityResult = try await tool.execute(args: ["category": .string("utility")])
        if case .object(let dict) = utilityResult.json {
            XCTAssertNotNil(dict["utility"], "Should have utility category")
            XCTAssertNil(dict["user"], "Should not have user category when filtered")
            XCTAssertNil(dict["system"], "Should not have system category when filtered")
        }
        XCTAssertTrue(utilityResult.humanSummary.contains("utility apps"))
    }
    
    func test_listAppsTool_appsSortedAlphabetically() async throws {
        let tool = SystemListAppsTool()
        let result = try await tool.execute(args: [:])
        
        if case .object(let dict) = result.json {
            // Check each category is sorted
            for category in ["user", "system", "utility"] {
                if case .array(let apps) = dict[category] {
                    let appNames = apps.compactMap { $0.stringValue }
                    let sortedNames = appNames.sorted { $0.lowercased() < $1.lowercased() }
                    XCTAssertEqual(appNames, sortedNames, "\(category) apps should be sorted alphabetically")
                }
            }
        }
    }
    
    func test_listAppsTool_findsSystemApps() async throws {
        let tool = SystemListAppsTool()
        let result = try await tool.execute(args: ["category": .string("system")])
        
        if case .object(let dict) = result.json,
           case .array(let apps) = dict["system"] {
            let appNames = apps.compactMap { $0.stringValue }
            // Calendar should always be present in system apps
            XCTAssertTrue(appNames.contains("Calendar"), "Calendar should be in system apps")
        } else {
            XCTFail("Expected system apps array")
        }
    }
    
    // MARK: - Tool Registry Integration
    
    func test_allSystemToolsRegistered() async throws {
        let registry = ToolRegistry.makeTestInstance()
        await registry.registerDefaultTools()
        
        // Check all system tools are registered
        let systemToolNames = [
            "system.open_app",
            "system.open_url",
            "system.open_path",
            "system.reveal_in_finder",
            "system.open_folder_special",
            "system.open_settings",
            "system.search_files",
            "system.search_apps",
            "system.list_apps",
            "system.run_shortcut",
            "system.list_shortcuts"
        ]
        
        for toolName in systemToolNames {
            let tool = await registry.tool(named: toolName)
            XCTAssertNotNil(tool, "Tool '\(toolName)' should be registered")
        }
    }
}

// MARK: - SystemToolError Tests

final class SystemToolErrorTests: XCTestCase {
    
    func test_notFoundError_hasDescriptiveMessage() {
        let error = SystemToolError.notFound("Application 'TestApp'")
        XCTAssertEqual(error.localizedDescription, "Application 'TestApp' not found")
    }
    
    func test_failedError_hasDescriptiveMessage() {
        let error = SystemToolError.failed("Connection timeout")
        XCTAssertEqual(error.localizedDescription, "Operation failed: Connection timeout")
    }
    
    func test_invalidArgumentError_hasDescriptiveMessage() {
        let error = SystemToolError.invalidArgument("URL must not be empty")
        XCTAssertEqual(error.localizedDescription, "Invalid argument: URL must not be empty")
    }
}
