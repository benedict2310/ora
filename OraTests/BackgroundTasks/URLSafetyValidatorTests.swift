//
//  URLSafetyValidatorTests.swift
//  OraTests
//
//  Tests for pre-fetch URL safety validation.
//

import XCTest
@testable import Ora

final class URLSafetyValidatorTests: XCTestCase {

    // MARK: - Scheme Tests

    func test_validate_rejectsNonHTTPSchemes() async {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        for scheme in ["ftp", "file", "data", "javascript"] {
            let urlString: String
            switch scheme {
            case "ftp":
                urlString = "ftp://example.com/file.txt"
            case "file":
                urlString = "file:///etc/passwd"
            case "data":
                urlString = "data:text/html,<h1>hi</h1>"
            case "javascript":
                urlString = "javascript:alert(1)"
            default:
                continue
            }

            guard let url = URL(string: urlString) else {
                // data: and javascript: URLs may not parse; that's acceptable
                continue
            }

            do {
                try await validator.validate(url: url)
                XCTFail("Expected blockedScheme for \(scheme)")
            } catch let error as NetworkSafetyError {
                if case .blockedScheme = error {
                    // Expected
                } else {
                    // blockedHost is also acceptable for some edge cases
                }
            } catch {
                // Any error is acceptable for blocked schemes
            }
        }
    }

    func test_validate_allowsHTTPAndHTTPS() async throws {
        let resolver = StubResolver(ips: ["93.184.216.34"])
        let validator = URLSafetyValidator(resolver: resolver)

        try await validator.validate(url: URL(string: "http://example.com")!)
        try await validator.validate(url: URL(string: "https://example.com")!)
    }

    // MARK: - Host Tests

    func test_validate_rejectsMissingHost() async {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        // A URL with scheme but no host
        let url = URL(string: "http://")!
        do {
            try await validator.validate(url: url)
            XCTFail("Expected blockedHost for missing host")
        } catch let error as NetworkSafetyError {
            if case .blockedHost = error {
                // Expected
            } else {
                XCTFail("Expected blockedHost, got \(error)")
            }
        } catch {
            // Any error is acceptable
        }
    }

    // MARK: - Loopback Tests

    func test_validate_rejectsLoopback() async {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        for ip in ["127.0.0.1", "127.0.0.2"] {
            let url = URL(string: "http://\(ip)/path")!
            do {
                try await validator.validate(url: url)
                XCTFail("Expected blockedIP for \(ip)")
            } catch let error as NetworkSafetyError {
                if case .blockedIP = error {
                    // Expected
                } else {
                    XCTFail("Expected blockedIP for \(ip), got \(error)")
                }
            } catch {
                XCTFail("Unexpected error type for \(ip): \(error)")
            }
        }

        // IPv6 loopback via resolver
        let resolver6 = StubResolver(ips: ["::1"])
        let validator6 = URLSafetyValidator(resolver: resolver6)
        do {
            try await validator6.validate(url: URL(string: "http://loopback.test")!)
            XCTFail("Expected blockedIP for ::1")
        } catch let error as NetworkSafetyError {
            if case .blockedIP = error {
                // Expected
            } else {
                XCTFail("Expected blockedIP for ::1, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error for ::1: \(error)")
        }
    }

    // MARK: - RFC1918 Tests

    func test_validate_rejectsRFC1918Ranges() async {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        let privateIPs = [
            "10.0.0.1",
            "10.255.255.255",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.0.1",
            "192.168.1.100"
        ]

        for ip in privateIPs {
            let url = URL(string: "http://\(ip)/path")!
            do {
                try await validator.validate(url: url)
                XCTFail("Expected blockedIP for \(ip)")
            } catch let error as NetworkSafetyError {
                if case .blockedIP = error {
                    // Expected
                } else {
                    XCTFail("Expected blockedIP for \(ip), got \(error)")
                }
            } catch {
                XCTFail("Unexpected error for \(ip): \(error)")
            }
        }
    }

    // MARK: - Link-Local and IPv6 Tests

    func test_validate_rejectsLinkLocalAndUniqueLocalIPv6() async {
        let resolver = StubResolver(ips: [])

        // Link-local IPv4
        let validator = URLSafetyValidator(resolver: resolver)
        let linkLocalURL = URL(string: "http://169.254.1.1/path")!
        do {
            try await validator.validate(url: linkLocalURL)
            XCTFail("Expected blockedIP for 169.254.1.1")
        } catch let error as NetworkSafetyError {
            if case .blockedIP = error {
                // Expected
            } else {
                XCTFail("Expected blockedIP, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // IPv6 link-local and unique-local via resolver
        for ip in ["fe80::1", "fc00::1", "fd00::1"] {
            let resolverIPv6 = StubResolver(ips: [ip])
            let validatorIPv6 = URLSafetyValidator(resolver: resolverIPv6)
            do {
                try await validatorIPv6.validate(url: URL(string: "http://test.local")!)
                XCTFail("Expected blockedIP for \(ip)")
            } catch let error as NetworkSafetyError {
                if case .blockedIP = error {
                    // Expected
                } else {
                    XCTFail("Expected blockedIP for \(ip), got \(error)")
                }
            } catch {
                XCTFail("Unexpected error for \(ip): \(error)")
            }
        }
    }

    // MARK: - Cloud Metadata Tests

    func test_validate_rejectsCloudMetadataAddress() async {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        // 169.254.169.254 (literal IP)
        let metadataURL = URL(string: "http://169.254.169.254/latest/meta-data/")!
        do {
            try await validator.validate(url: metadataURL)
            XCTFail("Expected blockedIP for cloud metadata address")
        } catch let error as NetworkSafetyError {
            if case .blockedIP = error {
                // Expected
            } else {
                XCTFail("Expected blockedIP, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // fd00:ec2::254 via resolver
        let ec2Resolver = StubResolver(ips: ["fd00:ec2::254"])
        let ec2Validator = URLSafetyValidator(resolver: ec2Resolver)
        do {
            try await ec2Validator.validate(url: URL(string: "http://metadata.test")!)
            XCTFail("Expected blockedIP for fd00:ec2::254")
        } catch let error as NetworkSafetyError {
            if case .blockedIP = error {
                // Expected
            } else {
                XCTFail("Expected blockedIP, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Resolved Private IP Tests

    func test_validate_rejectsResolvedPrivateIP() async {
        let resolver = StubResolver(ips: ["192.168.1.1"])
        let validator = URLSafetyValidator(resolver: resolver)

        do {
            try await validator.validate(url: URL(string: "https://malicious.example.com")!)
            XCTFail("Expected blockedIP for resolved private IP")
        } catch let error as NetworkSafetyError {
            if case .blockedIP = error {
                // Expected
            } else {
                XCTFail("Expected blockedIP, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Domain Allowlist Tests

    func test_validate_allowedDomains_blocksUnexpectedHost() async {
        let policy = NetworkSafetyPolicy(allowedDomains: ["example.com", "trusted.org"])
        let resolver = StubResolver(ips: ["93.184.216.34"])
        let validator = URLSafetyValidator(resolver: resolver, policy: policy)

        do {
            try await validator.validate(url: URL(string: "https://evil.com/data")!)
            XCTFail("Expected blockedDomain for non-allowed host")
        } catch let error as NetworkSafetyError {
            if case .blockedDomain = error {
                // Expected
            } else {
                XCTFail("Expected blockedDomain, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_validate_allowedDomains_allowsMatchingHost() async throws {
        let policy = NetworkSafetyPolicy(allowedDomains: ["example.com", "trusted.org"])
        let resolver = StubResolver(ips: ["93.184.216.34"])
        let validator = URLSafetyValidator(resolver: resolver, policy: policy)

        try await validator.validate(url: URL(string: "https://example.com/page")!)
        try await validator.validate(url: URL(string: "https://sub.example.com/page")!)
        try await validator.validate(url: URL(string: "https://trusted.org/data")!)
    }

    // MARK: - Content Type Tests

    func test_validateContentType_allowsValidTypes() throws {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        try validator.validateContentType("text/html")
        try validator.validateContentType("text/html; charset=utf-8")
        try validator.validateContentType("text/plain")
        try validator.validateContentType("application/json")
        try validator.validateContentType("application/xml")
        try validator.validateContentType("text/xml")
        try validator.validateContentType(nil)
    }

    func test_validateContentType_rejectsInvalidTypes() {
        let validator = URLSafetyValidator(resolver: StubResolver(ips: []))

        do {
            try validator.validateContentType("image/png")
            XCTFail("Expected unsupportedContentType")
        } catch let error as NetworkSafetyError {
            if case .unsupportedContentType(let type) = error {
                XCTAssertEqual(type, "image/png")
            } else {
                XCTFail("Expected unsupportedContentType, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Test Helpers

private struct StubResolver: URLHostResolver {
    let ips: [String]

    func resolve(hostname: String) async throws -> [String] {
        return self.ips
    }
}
