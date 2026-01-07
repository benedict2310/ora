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
