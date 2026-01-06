//
//  ResponseTextStreamParser.swift
//  Ora
//
//  Extracts response text from streaming JSON output.
//

import Foundation

struct ResponseTextStreamParser: Sendable {

    enum ResponseType: String {
        case response
        case toolCall = "tool_call"
        case proposal
        case error
    }

    private var buffer = ""
    private var responseType: ResponseType?
    private var typeFieldEndIndex: String.Index?
    private var textValueStartIndex: String.Index?
    private var textScanIndex: String.Index?
    private var isTextComplete = false
    private var isEscaping = false
    private var pendingUnicodeDigits: String?

    mutating func append(_ fragment: String) -> [String] {
        guard !fragment.isEmpty else { return [] }

        buffer.append(fragment)

        if responseType == nil {
            parseResponseTypeIfAvailable()
        }

        guard responseType == .response else { return [] }

        if textValueStartIndex == nil {
            if let start = findStringValueStart(
                forKey: "text",
                in: buffer,
                startingAt: typeFieldEndIndex ?? buffer.startIndex
            ) {
                textValueStartIndex = start
                textScanIndex = start
            }
        }

        guard let _ = textScanIndex, !isTextComplete else { return [] }

        let newText = consumeText(from: buffer)
        guard !newText.isEmpty else { return [] }
        return [newText]
    }

    private mutating func parseResponseTypeIfAvailable() {
        guard responseType == nil else { return }
        guard let (value, endIndex) = parseStringValue(
            forKey: "type",
            in: buffer,
            startingAt: buffer.startIndex
        ) else { return }

        responseType = ResponseType(rawValue: value)
        typeFieldEndIndex = endIndex
    }

    private func parseStringValue(
        forKey key: String,
        in buffer: String,
        startingAt searchStart: String.Index
    ) -> (value: String, endIndex: String.Index)? {
        guard let valueStart = findStringValueStart(forKey: key, in: buffer, startingAt: searchStart) else {
            return nil
        }
        let quotedStart = buffer.index(before: valueStart)
        return parseJSONString(in: buffer, startingAt: quotedStart)
    }

    private func findStringValueStart(
        forKey key: String,
        in buffer: String,
        startingAt searchStart: String.Index
    ) -> String.Index? {
        let keyToken = "\"\(key)\""
        guard let keyRange = buffer.range(of: keyToken, range: searchStart..<buffer.endIndex) else {
            return nil
        }

        var index = keyRange.upperBound
        while index < buffer.endIndex, buffer[index].isWhitespace {
            index = buffer.index(after: index)
        }

        if index < buffer.endIndex, buffer[index] != ":" {
            guard let colonIndex = buffer[index...].firstIndex(of: ":") else {
                return nil
            }
            index = buffer.index(after: colonIndex)
        } else if index < buffer.endIndex {
            index = buffer.index(after: index)
        }

        while index < buffer.endIndex, buffer[index].isWhitespace {
            index = buffer.index(after: index)
        }

        guard index < buffer.endIndex, buffer[index] == "\"" else { return nil }
        return buffer.index(after: index)
    }

    private func parseJSONString(
        in buffer: String,
        startingAt index: String.Index
    ) -> (value: String, endIndex: String.Index)? {
        guard index < buffer.endIndex, buffer[index] == "\"" else { return nil }
        var value = ""
        var currentIndex = buffer.index(after: index)
        var isEscaping = false

        while currentIndex < buffer.endIndex {
            let character = buffer[currentIndex]
            if isEscaping {
                value.append(character)
                isEscaping = false
                currentIndex = buffer.index(after: currentIndex)
                continue
            }

            if character == "\\" {
                isEscaping = true
                currentIndex = buffer.index(after: currentIndex)
                continue
            }

            if character == "\"" {
                return (value, buffer.index(after: currentIndex))
            }

            value.append(character)
            currentIndex = buffer.index(after: currentIndex)
        }

        return nil
    }

    private mutating func consumeText(from buffer: String) -> String {
        guard let startIndex = textScanIndex else { return "" }

        var output = ""
        var currentIndex = startIndex

        while currentIndex < buffer.endIndex {
            let character = buffer[currentIndex]

            if let pending = pendingUnicodeDigits {
                if character.isHexDigit {
                    pendingUnicodeDigits = pending + String(character)
                    currentIndex = buffer.index(after: currentIndex)
                    if pendingUnicodeDigits?.count == 4 {
                        if let scalarValue = UInt32(pendingUnicodeDigits ?? "", radix: 16),
                           let scalar = UnicodeScalar(scalarValue) {
                            output.append(Character(scalar))
                        }
                        pendingUnicodeDigits = nil
                        isEscaping = false
                    }
                    continue
                } else {
                    output.append("u")
                    output.append(contentsOf: pending)
                    pendingUnicodeDigits = nil
                    isEscaping = false
                    continue
                }
            }

            if isEscaping {
                switch character {
                case "\"":
                    output.append("\"")
                case "\\":
                    output.append("\\")
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "u":
                    pendingUnicodeDigits = ""
                default:
                    output.append(character)
                }

                if pendingUnicodeDigits == nil {
                    isEscaping = false
                }
                currentIndex = buffer.index(after: currentIndex)
                continue
            }

            if character == "\\" {
                isEscaping = true
                currentIndex = buffer.index(after: currentIndex)
                continue
            }

            if character == "\"" {
                isTextComplete = true
                textScanIndex = buffer.index(after: currentIndex)
                return output
            }

            output.append(character)
            currentIndex = buffer.index(after: currentIndex)
        }

        textScanIndex = buffer.endIndex
        return output
    }
}
