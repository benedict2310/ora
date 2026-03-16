//
//  SummaryPrompt.swift
//  Ora
//
//  Deterministic prompt builder for background task summarization.
//

import Foundation

struct SummaryPrompt: Sendable {

    /// Build a prompt for the LLM to generate a markdown summary from sanitized fetched content.
    static func build(sanitizedPages: [SanitizedPage], label: String?) -> String {
        let topic = label ?? "the following web pages"

        let combinedContent = sanitizedPages
            .map(\.sanitizedText)
            .joined(separator: "\n\n")

        let systemInstruction = """
            You are a research assistant. Your task is to produce a concise markdown summary \
            of fetched web content. Follow these rules strictly:
            - Output ONLY the summary in markdown format.
            - Use bullet points for key findings.
            - Keep the summary under 500 words.
            - Do not include any preamble, explanation of your process, or sign-off.
            - If the content is insufficient or empty, output: "No meaningful content could be summarized."
            """

        let userPrompt = """
            Summarize the research on "\(topic)" from the content below.

            \(combinedContent)
            """

        return """
            <|im_start|>system
            \(systemInstruction)<|im_end|>
            <|im_start|>user
            \(userPrompt)<|im_end|>
            <|im_start|>assistant
            """
    }
}
