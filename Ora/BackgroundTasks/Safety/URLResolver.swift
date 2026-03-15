//
//  URLResolver.swift
//  Ora
//
//  Injectable hostname resolution for network safety validation.
//

import Foundation

protocol URLHostResolver: Sendable {
    func resolve(hostname: String) async throws -> [String]
}

struct SystemURLResolver: URLHostResolver {

    func resolve(hostname: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(hostname, nil, &hints, &result)

            guard status == 0, let firstResult = result else {
                if let result {
                    freeaddrinfo(result)
                }
                continuation.resume(throwing: NSError(
                    domain: "URLResolver",
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "DNS resolution failed for host."]
                ))
                return
            }

            defer { freeaddrinfo(firstResult) }

            var addresses: [String] = []
            var current = Optional(firstResult)

            while let info = current {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                let nameInfoStatus = getnameinfo(
                    info.pointee.ai_addr,
                    info.pointee.ai_addrlen,
                    &hostBuffer,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if nameInfoStatus == 0 {
                    let address = String(cString: hostBuffer)
                    if !addresses.contains(address) {
                        addresses.append(address)
                    }
                }

                current = info.pointee.ai_next
            }

            continuation.resume(returning: addresses)
        }
    }
}
