//
//  URLSafetyValidator.swift
//  Ora
//
//  Pre-fetch URL validation to prevent SSRF and private-network access.
//

import Foundation
import os

struct URLSafetyValidator: Sendable {

    private let resolver: any URLHostResolver
    private let policy: NetworkSafetyPolicy
    private let logger = Logger.ora(category: "network-safety")

    init(
        resolver: any URLHostResolver = SystemURLResolver(),
        policy: NetworkSafetyPolicy = NetworkSafetyPolicy()
    ) {
        self.resolver = resolver
        self.policy = policy
    }

    // MARK: - Public

    func validate(url: URL) async throws {
        try self.validateScheme(url)
        try self.validateHost(url)

        let host = url.host ?? ""

        // Check if the host is already a literal IP
        if Self.isIPAddress(host) {
            try self.validateIPAddress(host)
        } else {
            // Resolve hostname and check resolved IPs
            try self.validateDomainAllowlist(host)
            let resolvedIPs = try await self.resolver.resolve(hostname: host)
            for ip in resolvedIPs {
                try self.validateIPAddress(ip)
            }
        }
    }

    // MARK: - Scheme

    private func validateScheme(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            let scheme = url.scheme ?? "none"
            self.logger.notice("Blocked URL with scheme: \(scheme)")
            throw NetworkSafetyError.blockedScheme(scheme)
        }
    }

    // MARK: - Host

    private func validateHost(_ url: URL) throws {
        guard let host = url.host, !host.isEmpty else {
            self.logger.notice("Blocked URL with missing host")
            throw NetworkSafetyError.blockedHost("empty")
        }
    }

    // MARK: - Domain Allowlist

    private func validateDomainAllowlist(_ host: String) throws {
        guard let allowedDomains = self.policy.allowedDomains else {
            return
        }

        let normalizedHost = host.lowercased()
        let matched = allowedDomains.contains { domain in
            let normalizedDomain = domain.lowercased()
            return normalizedHost == normalizedDomain
                || normalizedHost.hasSuffix("." + normalizedDomain)
        }

        if !matched {
            self.logger.notice("Blocked URL with domain not in allowlist")
            throw NetworkSafetyError.blockedDomain(host)
        }
    }

    // MARK: - IP Validation

    private func validateIPAddress(_ ip: String) throws {
        if Self.isPrivateIP(ip) {
            self.logger.notice("Blocked private IP address")
            throw NetworkSafetyError.blockedIP(ip)
        }
    }

    // MARK: - IP Classification

    static func isIPAddress(_ string: String) -> Bool {
        var addr4 = in_addr()
        var addr6 = in6_addr()
        return inet_pton(AF_INET, string, &addr4) == 1
            || inet_pton(AF_INET6, string, &addr6) == 1
    }

    static func isPrivateIP(_ ip: String) -> Bool {
        // Try IPv4
        var addr4 = in_addr()
        if inet_pton(AF_INET, ip, &addr4) == 1 {
            return self.isPrivateIPv4(addr4)
        }

        // Try IPv6
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, ip, &addr6) == 1 {
            return self.isPrivateIPv6(addr6)
        }

        // If it looks like an IPv6 in brackets, strip them
        let stripped = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if stripped != ip {
            if inet_pton(AF_INET6, stripped, &addr6) == 1 {
                return self.isPrivateIPv6(addr6)
            }
        }

        return false
    }

    private static func isPrivateIPv4(_ addr: in_addr) -> Bool {
        let ip = UInt32(bigEndian: addr.s_addr)
        let b0 = (ip >> 24) & 0xFF
        let b1 = (ip >> 16) & 0xFF

        // Loopback: 127.0.0.0/8
        if b0 == 127 { return true }

        // RFC1918: 10.0.0.0/8
        if b0 == 10 { return true }

        // RFC1918: 172.16.0.0/12
        if b0 == 172 && (b1 >= 16 && b1 <= 31) { return true }

        // RFC1918: 192.168.0.0/16
        if b0 == 192 && b1 == 168 { return true }

        // Link-local: 169.254.0.0/16 (includes cloud metadata 169.254.169.254)
        if b0 == 169 && b1 == 254 { return true }

        // 0.0.0.0
        if ip == 0 { return true }

        return false
    }

    private static func isPrivateIPv6(_ addr: in6_addr) -> Bool {
        let bytes = withUnsafeBytes(of: addr) { Array($0) }

        // ::1 (loopback)
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }

        // :: (unspecified)
        if bytes.allSatisfy({ $0 == 0 }) {
            return true
        }

        // fe80::/10 (link-local)
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
            return true
        }

        // fc00::/7 (unique local, covers fc00:: and fd00::)
        if (bytes[0] & 0xFE) == 0xFC {
            return true
        }

        // ::ffff:0:0/96 (IPv4-mapped IPv6) - check the embedded IPv4
        let isIPv4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 })
            && bytes[10] == 0xFF && bytes[11] == 0xFF
        if isIPv4Mapped {
            var embedded = in_addr()
            embedded.s_addr = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            embedded.s_addr = embedded.s_addr.bigEndian
            return self.isPrivateIPv4(embedded)
        }

        return false
    }

    // MARK: - Content Type

    func validateContentType(_ contentType: String?) throws {
        guard let rawContentType = contentType, !rawContentType.isEmpty else {
            // Allow missing content type (will be treated as text/html by worker)
            return
        }

        let normalized = rawContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? rawContentType.lowercased()

        let allowed = self.policy.allowedContentTypes.contains { $0.lowercased() == normalized }
        if !allowed {
            self.logger.notice("Blocked response with content type: \(normalized)")
            throw NetworkSafetyError.unsupportedContentType(normalized)
        }
    }
}
