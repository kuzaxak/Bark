// Licensed under GPL-3.0. See LICENSE.
//
//  FilterPreprocessor.swift
//  Nook
//
//  uBlock Origin's `!#if` / `!#else` / `!#endif` directives. adblock-rust reads them as
//  comments, so without this every branch of every conditional loads, including rules
//  uBO keeps for one browser (a Firefox-only JSON.parse hook tripped YouTube's check).
//

import Foundation

enum FilterPreprocessor {
    /// Bark runs desktop Chromium and understands uBO scriptlet syntax. Neither
    /// the host CPU nor Chromium itself implies a mobile or extension environment,
    /// or support for HTML response filtering or IP-address rules.
    static let chromiumDesktop: Set<String> = ["env_chromium", "ext_ublock"]

    static func apply(_ text: String, environment: Set<String> = chromiumDesktop) -> String {
        guard text.contains("!#if") else { return text }
        var branches: [Bool] = []
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("!#if ") {
                branches.append(evaluate(line.dropFirst(5), environment: environment))
            } else if line.hasPrefix("!#else") {
                if !branches.isEmpty { branches[branches.count - 1].toggle() }
            } else if line.hasPrefix("!#endif") {
                _ = branches.popLast()
            } else if !branches.contains(false) {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    // ponytail: no parentheses; a parenthesised condition drops its block. None of the lists use one.
    static func evaluate(_ expression: Substring, environment: Set<String> = chromiumDesktop) -> Bool {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.contains("(") else { return false }
        return expression.components(separatedBy: "||").contains { clause in
            clause.components(separatedBy: "&&").allSatisfy { term in
                let token = term.trimmingCharacters(in: .whitespaces)
                return token.hasPrefix("!")
                    ? !environment.contains(String(token.dropFirst()))
                    : environment.contains(token)
            }
        }
    }
}
