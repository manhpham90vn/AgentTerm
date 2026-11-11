@testable import AgenttyHost
import AgenttyProtocol
import XCTest

final class AccountUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_380_000)

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// An outside world with nothing in it but what a test puts there.
    private func environment(
        keychain: [String: String] = [:], files: [String: String] = [:], shell: [String: String] = [:],
        variables: [String: String] = [:], answers: [String: (Int, String)] = [:], asked: ((URLRequest) -> Void)? = nil
    ) -> AccountUsageFetcher.Environment {
        AccountUsageFetcher.Environment(
            keychain: { service, account in keychain[service + (account.map { "/" + $0 } ?? "")] },
            file: { files[$0].map { Data($0.utf8) } },
            shell: { shell[$0] },
            http: { request in
                asked?(request)
                return answers[request.url?.absoluteString ?? ""].map { ($0.0, Data($0.1.utf8)) }
            },
            variables: variables, home: "/home/me", now: { self.now }
        )
    }

    // MARK: Claude Code

    private let claudeAnswer = #"""
    {"five_hour":{"utilization":56.0,"resets_at":"2026-11-11T11:50:00.351475+00:00"},
     "limits":[
      {"kind":"session","percent":58,"resets_at":"2026-11-11T11:50:00.920147+00:00","scope":null},
      {"kind":"weekly_all","percent":30,"resets_at":"2026-11-13T21:00:00.920164+00:00","scope":null},
      {"kind":"weekly_scoped","percent":41,"resets_at":"2026-11-13T21:00:00.920280+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}}],
     "extra_usage":{"is_enabled":false,"monthly_limit":10000,"used_credits":0.0,"currency":"USD","decimal_places":2}}
    """#

    func testClaudeListsItsLimitsAsItsUsageScreenDoes() {
        let usage = AccountUsageFetcher.parseClaude(json(claudeAnswer), now: now)
        XCTAssertFalse(usage.showsRemaining, "Claude Code speaks of what is used")
        XCTAssertEqual(usage.limits.map(\.title), ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertEqual(usage.limits.map(\.shortTitle), ["Session", "Week", "Week Fable"])
        XCTAssertEqual(usage.limits.map(\.usedPercent), [58, 30, 41])
        XCTAssertEqual(usage.limits.map(usage.percentText), ["58% used", "30% used", "41% used"])
        XCTAssertEqual(usage.limits[0].resetsAt.map { Int($0.timeIntervalSince1970) }, 1_794_397_800)
        XCTAssertEqual(usage.notes, [AccountUsageNote(label: "Extra usage", value: "Off")])
        XCTAssertNil(usage.problem)
    }

    func testClaudeUnderstandsTheOlderAnswerAndExtraUsage() {
        let usage = AccountUsageFetcher.parseClaude(json(#"{"five_hour":{"utilization":62,"resets_at":"2026-09-20T22:20:00.095287+00:00"},"seven_day":{"utilization":48,"resets_at":null},"seven_day_opus":null,"extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":1250,"currency":"USD","decimal_places":2}}"#), now: now)
        XCTAssertEqual(usage.limits.map(\.title), ["Current session", "Current week (all models)"])
        XCTAssertEqual(usage.limits.map(\.usedPercent), [62, 48])
        XCTAssertEqual(usage.notes, [AccountUsageNote(label: "Extra usage", value: "12.50 USD of 100.00 USD used")])
    }

    func testClaudeCountsBankedLimitResetsOnlyWhereAnthropicReportsThem() {
        // What Claude Code's own sign-in is answered with: nothing to count, so nothing is said.
        let withheld = AccountUsageFetcher.parseClaude(json(#"{"limits":[{"kind":"session","percent":5}],"cedar_ember":{"eligible":false,"ineligible_reason":"surface","grants":[]}}"#), now: now)
        XCTAssertEqual(withheld.notes, [])
        let reported = AccountUsageFetcher.parseClaude(json(#"""
        {"limits":[{"kind":"session","percent":5}],"cedar_ember":{"eligible":true,"grants":[
          {"resets_left":2,"resets_total":2,"starts_at":"2026-11-01T00:00:00Z","ends_at":"2026-12-05T00:00:00Z","paused":false},
          {"resets_left":1,"resets_total":1,"ends_at":"2026-11-20T00:00:00Z","paused":false},
          {"resets_left":4,"ends_at":"2026-11-30T00:00:00Z","paused":true},
          {"resets_left":8,"ends_at":"2026-11-01T00:00:00Z","paused":false},
          {"resets_left":9,"starts_at":"2027-01-01T00:00:00Z","paused":false}]}}
        """#), now: now)
        XCTAssertEqual(reported.notes.first?.label, "Limit resets")
        XCTAssertEqual(reported.notes.first?.value.hasPrefix("3 available, the first expires "), true, "paused, ended and not yet started ones are not counted")
        let none = AccountUsageFetcher.parseClaude(json(#"{"limits":[{"kind":"session","percent":5}],"cedar_ember":{"eligible":true,"grants":[]}}"#), now: now)
        XCTAssertEqual(none.notes, [AccountUsageNote(label: "Limit resets", value: "0 available")])
    }

    func testClaudePlanNames() {
        XCTAssertEqual(AccountUsageFetcher.claudePlan(subscription: "max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(AccountUsageFetcher.claudePlan(subscription: "pro", tier: "default_claude_ai"), "Pro")
        XCTAssertNil(AccountUsageFetcher.claudePlan(subscription: nil, tier: "x"))
    }

    func testClaudeSendsItsSignInToAnthropicOnly() {
        var requests: [URLRequest] = []
        let login = #"{"claudeAiOauth":{"accessToken":"tok-claude","refreshToken":"never-used","expiresAt":1794390000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}"#
        let usage = AccountUsageFetcher.fetch(agent: "claude", environment: environment(
            keychain: ["Claude Code-credentials": login],
            answers: ["https://api.anthropic.com/api/oauth/usage?cedar_ember=1": (200, claudeAnswer)], asked: { requests.append($0) }
        ))
        XCTAssertEqual(usage?.plan, "Max 5x")
        XCTAssertEqual(usage?.limits.count, 3)
        XCTAssertEqual(requests.map { $0.url?.host }, ["api.anthropic.com"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-claude")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testAnExpiredSignInIsNotSentAndNeverRenewed() {
        var requests = 0
        let login = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1794370000000,"subscriptionType":"pro"}}"#
        let usage = AccountUsageFetcher.fetch(agent: "claude", environment: environment(keychain: ["Claude Code-credentials": login], asked: { _ in requests += 1 }))
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(usage?.plan, "Pro")
        XCTAssertEqual(usage?.problem?.contains("renewing"), true)
        XCTAssertEqual(usage?.limits, [])
    }

    func testMissingSignInsAndRefusalsAreSaidPlainly() {
        XCTAssertEqual(AccountUsageFetcher.fetch(agent: "claude", environment: environment())?.problem, "Claude Code is not signed in with a claude.ai account on this Mac.")
        XCTAssertEqual(AccountUsageFetcher.fetch(agent: "codex", environment: environment())?.problem, "Codex is not signed in with a ChatGPT account on this Mac.")
        XCTAssertEqual(AccountUsageFetcher.fetch(agent: "agy", environment: environment())?.problem, "Antigravity is not signed in on this Mac.")
        XCTAssertEqual(AccountUsageFetcher.fetch(agent: "copilot", environment: environment())?.problem?.hasPrefix("No GitHub sign-in"), true)
        XCTAssertNil(AccountUsageFetcher.fetch(agent: "zsh", environment: environment()))
        let refused = AccountUsageFetcher.fetch(agent: "codex", environment: environment(
            files: ["/home/me/.codex/auth.json": #"{"tokens":{"access_token":"t"}}"#],
            answers: ["https://chatgpt.com/backend-api/wham/usage": (401, "{}")]
        ))
        XCTAssertEqual(refused?.problem, "ChatGPT did not accept the sign-in. Send a message in Codex to renew it.")
        let unreachable = AccountUsageFetcher.fetch(agent: "codex", environment: environment(files: ["/home/me/.codex/auth.json": #"{"tokens":{"access_token":"t"}}"#]))
        XCTAssertEqual(unreachable?.problem, "ChatGPT could not be reached.")
    }

    // MARK: Codex

    private let codexAnswer = #"""
    {"plan_type":"plus","email":"me@example.com",
     "rate_limit":{"allowed":true,"limit_reached":false,
       "primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":8515,"reset_at":1794396857},
       "secondary_window":{"used_percent":97,"limit_window_seconds":604800,"reset_after_seconds":568,"reset_at":1794388910}},
     "code_review_rate_limit":null,"additional_rate_limits":null,
     "credits":{"has_credits":false,"unlimited":false,"balance":0},
     "rate_limit_reset_credits":{"available_count":2,"applicable_available_count":2}}
    """#

    func testCodexListsItsLimitsAsItsStatusDoes() {
        let usage = AccountUsageFetcher.parseCodex(json(codexAnswer), now: now)
        XCTAssertEqual(usage.plan, "Plus")
        XCTAssertTrue(usage.showsRemaining)
        XCTAssertEqual(usage.limits.map(\.title), ["5h limit", "Weekly limit"])
        XCTAssertEqual(usage.limits.map(\.shortTitle), ["5h", "Week"])
        XCTAssertEqual(usage.limits.map(usage.percentText), ["100% left", "3% left"])
        XCTAssertEqual(usage.limits[1].resetsAt, Date(timeIntervalSince1970: 1_794_388_910))
        XCTAssertEqual(usage.notes, [AccountUsageNote(label: "Limit resets", value: "2 available")])
    }

    func testCodexSaysWhenTheFirstBankedResetExpires() throws {
        var hosts: [String] = []
        let usage = AccountUsageFetcher.fetch(agent: "codex", environment: environment(
            files: ["/elsewhere/auth.json": #"{"tokens":{"access_token":"tok-codex","account_id":"acct-1","refresh_token":"never-used"}}"#],
            variables: ["CODEX_HOME": "/elsewhere"],
            answers: [
                "https://chatgpt.com/backend-api/wham/usage": (200, codexAnswer),
                "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits": (200, #"{"credits":[{"status":"redeemed","expires_at":"2026-11-12T00:00:00Z"},{"status":"available","expires_at":"2026-12-05T00:00:00Z"},{"status":"available","expires_at":"2026-11-20T00:00:00Z"}],"available_count":2}"#),
            ],
            asked: { request in
                hosts.append(request.url?.host ?? "")
                XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
            }
        ))
        XCTAssertEqual(hosts, ["chatgpt.com", "chatgpt.com"])
        let note = try XCTUnwrap(usage?.notes.first)
        XCTAssertTrue(note.value.hasPrefix("2 available, the first expires "), note.value)
        XCTAssertTrue(note.value.contains("20") || note.value.contains("19"), "the earliest of those still available: \(note.value)")
    }

    // MARK: Copilot

    func testCopilotListsPremiumRequests() {
        let usage = AccountUsageFetcher.parseCopilot(json(#"""
        {"copilot_plan":"individual","access_type_sku":"free_engaged_oss_quota","quota_reset_date":"2026-12-01","quota_reset_date_utc":"2026-12-01T00:00:00.000Z",
         "quota_snapshots":{"chat":{"unlimited":true,"percent_remaining":100.0},"completions":{"unlimited":true,"percent_remaining":100.0},
          "premium_interactions":{"unlimited":false,"percent_remaining":98.5,"remaining":1477,"entitlement":1500,"overage_permitted":false,"overage_count":0}}}
        """#), now: now)
        XCTAssertEqual(usage.plan, "Individual, free")
        XCTAssertEqual(usage.limits.map(\.title), ["Premium requests"])
        XCTAssertEqual(usage.limits.first?.detail, "1477 of 1500 left")
        XCTAssertEqual(usage.limits.map(usage.percentText), ["99% left"])
        XCTAssertEqual(usage.limits.first?.resetsAt, AgentHistory.parseDate("2026-12-01T00:00:00Z"))
        XCTAssertEqual(usage.notes.map(\.label), ["Chat", "Completions"])
    }

    func testCopilotUsesTheGitHubSignIn() {
        var authorization: String?
        let usage = AccountUsageFetcher.fetch(agent: "copilot", environment: environment(
            shell: ["gh auth token 2>/dev/null": "some shell greeting\ngho_abc\n"],
            answers: ["https://api.github.com/copilot_internal/user": (200, #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":50,"remaining":150,"entitlement":300}}}"#)],
            asked: { authorization = $0.value(forHTTPHeaderField: "Authorization") }
        ))
        XCTAssertEqual(authorization, "token gho_abc")
        XCTAssertEqual(usage?.limits.first?.detail, "150 of 300 left")
    }

    // MARK: Antigravity

    func testAntigravityListsEachGroupOfModels() {
        let summary = #"""
        {"groups":[
          {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
            {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-11-18T09:17:13Z","remainingFraction":0.5317},
            {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","resetTime":"2026-11-11T14:17:13Z","remainingFraction":1}]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","resetTime":"2026-11-18T09:17:13Z","remainingFraction":1},
            {"bucketId":"off","displayName":"Unused","window":"5h","disabled":true,"remainingFraction":1}]}]}
        """#
        var bodies: [String: [String: Any]] = [:]
        // go-keyring wraps what it stores.
        let login = "go-keyring-base64:" + Data(#"{"token":{"access_token":"tok-agy","refresh_token":"never-used","expiry":"2026-11-11T17:14:36.636828+07:00"},"auth_method":"oauth"}"#.utf8).base64EncodedString()
        let usage = AccountUsageFetcher.fetch(agent: "agy", environment: environment(
            keychain: ["gemini/antigravity": login],
            shell: ["agy --version 2>/dev/null": "1.6.0\n"],
            answers: [
                "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist": (200, #"{"cloudaicompanionProject":"proj-1","currentTier":{"name":"Antigravity"},"paidTier":{"name":"Google AI Pro"}}"#),
                "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary": (200, summary),
            ],
            asked: { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-agy")
                XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity/cli/1.6.0 darwin/arm64")
                XCTAssertTrue(request.url?.host?.hasSuffix("cloudcode-pa.googleapis.com") == true)
                bodies[request.url?.absoluteString ?? ""] = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        ))
        XCTAssertEqual(usage?.plan, "Google AI Pro")
        XCTAssertEqual(usage?.groups.map(\.title), ["Gemini Models", "Claude and GPT models"])
        XCTAssertEqual(usage?.groups.first?.limits.map(\.title), ["Weekly Limit", "Five Hour Limit"])
        XCTAssertEqual(usage?.groups.first?.limits.map(\.shortTitle), ["Week", "5h"])
        XCTAssertEqual(usage.map { $0.limits.map($0.percentText) }, ["53% left", "100% left", "100% left"], "a bucket that is switched off is left out")
        XCTAssertEqual(bodies["https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"]?["project"] as? String, "proj-1")
    }
}
