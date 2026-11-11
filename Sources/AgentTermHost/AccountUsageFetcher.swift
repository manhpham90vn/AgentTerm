#if os(macOS)
import AgentTermProtocol
import Foundation

/// Asks each agent's service what the signed-in account has used and has
/// left: the figures `/usage` shows in Claude Code and `/status` in Codex.
///
/// The services want the agent's own sign-in. It is read where the agent
/// keeps it on this Mac, used for the one request, and not kept. It is sent
/// only to the service that issued it, over HTTPS, and never refreshed or
/// written back: renewing it is the agent's business, and doing it here
/// could sign the agent out. Nothing of it is logged or sent to a client.
public enum AccountUsageFetcher {
    /// The outside world, so tests can stand in for it.
    public struct Environment {
        /// A generic password from the login keychain.
        public var keychain: (_ service: String, _ account: String?) -> String?
        public var file: (_ path: String) -> Data?
        /// The standard output of a command run through the login shell.
        public var shell: (_ command: String) -> String?
        public var http: (_ request: URLRequest) -> (status: Int, body: Data)?
        public var variables: [String: String]
        public var home: String
        public var now: () -> Date

        public init(
            keychain: @escaping (String, String?) -> String?, file: @escaping (String) -> Data?,
            shell: @escaping (String) -> String?, http: @escaping (URLRequest) -> (status: Int, body: Data)?,
            variables: [String: String] = [:], home: String = NSHomeDirectory(), now: @escaping () -> Date = Date.init
        ) {
            self.keychain = keychain
            self.file = file
            self.shell = shell
            self.http = http
            self.variables = variables
            self.home = home
            self.now = now
        }

        public static let live = Environment(
            keychain: { service, account in
                var arguments = ["find-generic-password", "-s", service]
                if let account { arguments += ["-a", account] }
                guard let result = Subprocess.run("/usr/bin/security", arguments + ["-w"], timeout: 10), result.status == 0 else { return nil }
                let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            },
            file: { FileManager.default.contents(atPath: $0) },
            shell: { command in
                guard let result = Subprocess.run(HostEnvironment.shell, ["-l", "-c", command], timeout: 15), result.status == 0 else { return nil }
                return String(decoding: result.output, as: UTF8.self)
            },
            http: AccountUsageFetcher.send,
            variables: ProcessInfo.processInfo.environment
        )
    }

    public static func fetch(agent: String, environment: Environment = .live) -> AccountUsage? {
        switch agent {
        case "claude": return claude(environment)
        case "codex": return codex(environment)
        case "copilot": return copilot(environment)
        case "agy": return antigravity(environment)
        default: return nil
        }
    }

    private static func failed(_ agent: String, _ problem: String, _ environment: Environment, showsRemaining: Bool = true) -> AccountUsage {
        AccountUsage(agent: agent, showsRemaining: showsRemaining, fetchedAt: environment.now(), problem: problem)
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return AgentHistory.parseDate(text) }
        guard let seconds = number(value), seconds > 0 else { return nil }
        // Some services count in milliseconds.
        return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
    }

    private static func request(_ url: String, bearer: String, headers: [String: String] = [:], body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: url), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func problem(status: Int?, service: String, signIn: String) -> String {
        switch status {
        case nil: return "\(service) could not be reached."
        case 401, 403: return "\(service) did not accept the sign-in. \(signIn)"
        case 429: return "\(service) asked to slow down. It is tried again shortly."
        default: return "\(service) answered with an error (\(status ?? 0))."
        }
    }

    // MARK: Claude Code

    private static func claude(_ environment: Environment) -> AccountUsage {
        // The keychain on a Mac; the file where Claude Code has no keychain.
        let directory = environment.variables["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? environment.home + "/.claude"
        let stored = environment.keychain("Claude Code-credentials", nil).map { Data($0.utf8) } ?? environment.file(directory + "/.credentials.json")
        guard let login = object(stored)?["claudeAiOauth"] as? [String: Any], let token = login["accessToken"] as? String, !token.isEmpty else {
            return failed("claude", "Claude Code is not signed in with a claude.ai account on this Mac.", environment, showsRemaining: false)
        }
        let plan = claudePlan(subscription: login["subscriptionType"] as? String, tier: login["rateLimitTier"] as? String)
        if let expires = date(login["expiresAt"]), expires <= environment.now() {
            // Claude Code renews it the next time it talks to its service.
            var usage = failed("claude", "Claude Code's sign-in needs renewing. It does that itself with its next message.", environment, showsRemaining: false)
            usage.plan = plan
            return usage
        }
        let headers = ["anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0"]
        // The query asks for the block that counts banked limit resets.
        let answer = request("https://api.anthropic.com/api/oauth/usage?cedar_ember=1", bearer: token, headers: headers).flatMap { environment.http($0) }
        guard let answer, answer.status == 200, let body = object(answer.body) else {
            var usage = failed("claude", problem(status: answer?.status, service: "Anthropic", signIn: "Send a message in Claude Code to renew it."), environment, showsRemaining: false)
            usage.plan = plan
            return usage
        }
        var usage = parseClaude(body, now: environment.now())
        usage.plan = plan
        return usage
    }

    static func claudePlan(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        var plan = subscription.prefix(1).uppercased() + subscription.dropFirst()
        // "default_claude_max_5x" names the size of a Max plan.
        if let size = tier?.split(separator: "_").last, size.hasSuffix("x"), Int(size.dropLast()) != nil { plan += " " + size }
        return plan
    }

    static func parseClaude(_ body: [String: Any], now: Date) -> AccountUsage {
        var limits: [AccountLimit] = []
        for (index, entry) in ((body["limits"] as? [[String: Any]]) ?? []).enumerated() {
            guard let percent = number(entry["percent"]) else { continue }
            let kind = entry["kind"] as? String ?? ""
            let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let title: String, short: String
            switch kind {
            case "session": (title, short) = ("Current session", "Session")
            case "weekly_all": (title, short) = ("Current week (all models)", "Week")
            default:
                let scope = model ?? kind.replacingOccurrences(of: "_", with: " ")
                (title, short) = (kind.hasPrefix("weekly") ? "Current week (\(scope))" : scope.capitalized, model.map { "Week \($0)" } ?? scope.capitalized)
            }
            limits.append(AccountLimit(id: "\(kind)-\(index)", title: title, shortTitle: short, usedPercent: percent, resetsAt: date(entry["resets_at"])))
        }
        if limits.isEmpty {
            // The older shape of the answer.
            for (key, title, short) in [("five_hour", "Current session", "Session"), ("seven_day", "Current week (all models)", "Week"), ("seven_day_opus", "Current week (Opus)", "Week Opus"), ("seven_day_sonnet", "Current week (Sonnet)", "Week Sonnet")] {
                guard let entry = body[key] as? [String: Any], let percent = number(entry["utilization"]) else { continue }
                limits.append(AccountLimit(id: key, title: title, shortTitle: short, usedPercent: percent, resetsAt: date(entry["resets_at"])))
            }
        }
        var notes: [AccountUsageNote] = []
        if let extra = body["extra_usage"] as? [String: Any] {
            let places = Int(number(extra["decimal_places"]) ?? 2)
            let scale = pow(10, Double(places))
            let currency = extra["currency"] as? String ?? "USD"
            func money(_ minor: Double) -> String { String(format: "%.\(places)f %@", minor / scale, currency) }
            if extra["is_enabled"] as? Bool == true {
                let used = number(extra["used_credits"]) ?? 0
                notes.append(AccountUsageNote(label: "Extra usage", value: number(extra["monthly_limit"]).map { "\(money(used)) of \(money($0)) used" } ?? "\(money(used)) used"))
            } else {
                notes.append(AccountUsageNote(label: "Extra usage", value: "Off"))
            }
        }
        // "Reset for free" in Claude's usage settings: resets of a limit that
        // are banked. Anthropic reports them only to some kinds of sign-in;
        // where it does not, nothing is said rather than "0".
        if let resets = body["cedar_ember"] as? [String: Any], resets["eligible"] as? Bool == true {
            var left = 0
            var expiries: [Date] = []
            for grant in (resets["grants"] as? [[String: Any]]) ?? [] {
                guard grant["paused"] as? Bool != true, let count = number(grant["resets_left"]), count > 0 else { continue }
                if let starts = date(grant["starts_at"]), starts > now { continue }
                let ends = date(grant["ends_at"])
                if let ends, ends <= now { continue }
                left += Int(count)
                if let ends { expiries.append(ends) }
            }
            var value = "\(left) available"
            if let first = expiries.min() { value += ", the first expires \(first.formatted(.dateTime.month(.abbreviated).day()))" }
            notes.insert(AccountUsageNote(label: "Limit resets", value: value), at: 0)
        }
        return AccountUsage(agent: "claude", showsRemaining: false, groups: limits.isEmpty ? [] : [AccountUsageGroup(limits: limits)], notes: notes, fetchedAt: now,
                            problem: limits.isEmpty ? "Anthropic reported no limits for this account." : nil)
    }

    // MARK: Codex

    private static func codex(_ environment: Environment) -> AccountUsage {
        let directory = environment.variables["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? environment.home + "/.codex"
        guard let tokens = object(environment.file(directory + "/auth.json"))?["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else { return failed("codex", "Codex is not signed in with a ChatGPT account on this Mac.", environment) }
        var headers = ["originator": "codex_cli_rs", "User-Agent": "codex_cli_rs"]
        if let account = tokens["account_id"] as? String, !account.isEmpty { headers["ChatGPT-Account-Id"] = account }
        guard let request = request("https://chatgpt.com/backend-api/wham/usage", bearer: token, headers: headers) else { return failed("codex", "Invalid request.", environment) }
        let answer = environment.http(request)
        guard let answer, answer.status == 200, let body = object(answer.body) else {
            return failed("codex", problem(status: answer?.status, service: "ChatGPT", signIn: "Send a message in Codex to renew it."), environment)
        }
        var usage = parseCodex(body, now: environment.now())
        // Reset credits that are banked run out; say when the first one does.
        if number((body["rate_limit_reset_credits"] as? [String: Any])?["available_count"]) ?? 0 > 0,
           let request = self.request("https://chatgpt.com/backend-api/wham/rate-limit-reset-credits", bearer: token, headers: headers),
           let answer = environment.http(request), answer.status == 200, let credits = object(answer.body)?["credits"] as? [[String: Any]] {
            let expiries = credits.filter { ($0["status"] as? String)?.lowercased() == "available" }.compactMap { date($0["expires_at"]) }
            if let first = expiries.min(), let index = usage.notes.firstIndex(where: { $0.label == "Limit resets" }) {
                usage.notes[index].value += ", the first expires \(first.formatted(.dateTime.month(.abbreviated).day()))"
            }
        }
        return usage
    }

    static func parseCodex(_ body: [String: Any], now: Date) -> AccountUsage {
        func limits(_ source: [String: Any]?, prefix: String) -> [AccountLimit] {
            ["primary_window", "secondary_window"].compactMap { key -> AccountLimit? in
                guard let window = source?[key] as? [String: Any], let used = number(window["used_percent"]) else { return nil }
                let minutes = Int((number(window["limit_window_seconds"]) ?? 0) / 60)
                let label = UsageLimit(windowMinutes: minutes, usedPercent: used, resetsAt: nil).label
                let resets = date(window["reset_at"]) ?? number(window["reset_after_seconds"]).map { now.addingTimeInterval($0) }
                return AccountLimit(id: prefix + key, title: (label == "Week" ? "Weekly" : label) + " limit", shortTitle: label, usedPercent: used, resetsAt: resets)
            }
        }
        var groups: [AccountUsageGroup] = []
        let main = limits(body["rate_limit"] as? [String: Any], prefix: "")
        if !main.isEmpty { groups.append(AccountUsageGroup(limits: main)) }
        let review = limits(body["code_review_rate_limit"] as? [String: Any], prefix: "review-")
        if !review.isEmpty { groups.append(AccountUsageGroup(title: "Code review", limits: review)) }
        for extra in (body["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let name = extra["limit_name"] as? String ?? extra["metered_feature"] as? String ?? "Other"
            let more = limits(extra["rate_limit"] as? [String: Any], prefix: name + "-")
            if !more.isEmpty { groups.append(AccountUsageGroup(title: name, limits: more)) }
        }

        var notes: [AccountUsageNote] = []
        if let resets = body["rate_limit_reset_credits"] as? [String: Any], let available = number(resets["available_count"]) {
            // A limit can be started over early with one of these.
            notes.append(AccountUsageNote(label: "Limit resets", value: "\(Int(available)) available"))
        }
        if let credits = body["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                notes.append(AccountUsageNote(label: "Credits", value: "Unlimited"))
            } else if credits["has_credits"] as? Bool == true, let balance = number(credits["balance"]) {
                notes.append(AccountUsageNote(label: "Credits", value: balance == balance.rounded() ? "\(Int(balance))" : String(format: "%.2f", balance)))
            }
        }
        let plan = (body["plan_type"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var problem: String?
        if (body["rate_limit"] as? [String: Any])?["limit_reached"] as? Bool == true { problem = "A limit is used up. Codex works again when it resets." }
        if groups.isEmpty { problem = "ChatGPT reported no limits for this account." }
        return AccountUsage(agent: "codex", plan: plan, showsRemaining: true, groups: groups, notes: notes, fetchedAt: now, problem: problem)
    }

    // MARK: Copilot CLI

    private static func copilot(_ environment: Environment) -> AccountUsage {
        // Copilot CLI signs in with the GitHub account, as `gh` does.
        let named = ["COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN"].lazy.compactMap { environment.variables[$0] }.first { !$0.isEmpty }
        let fromGH = { environment.shell("gh auth token 2>/dev/null")?.split(whereSeparator: \.isNewline).last.map(String.init) }
        guard let token = named ?? fromGH(), !token.isEmpty, !token.contains(" ") else {
            return failed("copilot", "No GitHub sign-in was found. Sign in with `gh auth login` to see Copilot's quota.", environment)
        }
        let headers = ["Editor-Version": "vscode/1.96.2", "Editor-Plugin-Version": "copilot-chat/0.26.7", "User-Agent": "GitHubCopilotChat/0.26.7", "X-Github-Api-Version": "2025-04-01"]
        guard var request = request("https://api.github.com/copilot_internal/user", bearer: token, headers: headers) else { return failed("copilot", "Invalid request.", environment) }
        request.setValue("token " + token, forHTTPHeaderField: "Authorization")
        let answer = environment.http(request)
        guard let answer, answer.status == 200, let body = object(answer.body) else {
            return failed("copilot", problem(status: answer?.status, service: "GitHub", signIn: "Sign in again with `gh auth login`."), environment)
        }
        return parseCopilot(body, now: environment.now())
    }

    static func parseCopilot(_ body: [String: Any], now: Date) -> AccountUsage {
        let resets = date(body["quota_reset_date_utc"]) ?? (body["quota_reset_date"] as? String).flatMap { AgentHistory.parseDate($0 + "T00:00:00Z") }
        let snapshots = body["quota_snapshots"] as? [String: Any] ?? [:]
        var limits: [AccountLimit] = []
        var notes: [AccountUsageNote] = []
        for (key, title, short) in [("premium_interactions", "Premium requests", "Premium"), ("chat", "Chat", "Chat"), ("completions", "Completions", "Completions")] {
            guard let snapshot = snapshots[key] as? [String: Any] else { continue }
            if snapshot["unlimited"] as? Bool == true {
                notes.append(AccountUsageNote(label: title, value: "Unlimited"))
                continue
            }
            guard let left = number(snapshot["percent_remaining"]) else { continue }
            var detail: String?
            if let remaining = number(snapshot["remaining"]) ?? number(snapshot["quota_remaining"]), let entitlement = number(snapshot["entitlement"]), entitlement > 0 {
                detail = "\(Int(remaining)) of \(Int(entitlement)) left"
            }
            limits.append(AccountLimit(id: key, title: title, shortTitle: short, usedPercent: max(0, 100 - left), resetsAt: resets, detail: detail))
            if snapshot["overage_permitted"] as? Bool == true, let over = number(snapshot["overage_count"]), over > 0 {
                notes.append(AccountUsageNote(label: "\(title) beyond the plan", value: "\(Int(over))"))
            }
        }
        var plan = (body["copilot_plan"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        if let sku = body["access_type_sku"] as? String, sku.contains("free") { plan = (plan.map { $0 + ", " } ?? "") + "free" }
        return AccountUsage(agent: "copilot", plan: plan, showsRemaining: true, groups: limits.isEmpty ? [] : [AccountUsageGroup(limits: limits)], notes: notes, fetchedAt: now,
                            problem: limits.isEmpty && notes.isEmpty ? "GitHub reported no Copilot quota for this account." : nil)
    }

    // MARK: Antigravity

    private static func antigravity(_ environment: Environment) -> AccountUsage {
        // `agy` keeps its Google sign-in in the keychain, wrapped the way
        // go-keyring wraps values, or in a file where there is no keychain.
        var stored = environment.keychain("gemini", "antigravity").map { value -> Data in
            let prefix = "go-keyring-base64:"
            return value.hasPrefix(prefix) ? Data(base64Encoded: String(value.dropFirst(prefix.count))) ?? Data() : Data(value.utf8)
        }
        if object(stored) == nil { stored = environment.file(environment.home + "/.gemini/antigravity-cli/antigravity-oauth-token") }
        let login = object(stored)
        let holder = login?["token"] as? [String: Any] ?? login
        guard let token = holder?["access_token"] as? String, !token.isEmpty else {
            return failed("agy", "Antigravity is not signed in on this Mac.", environment)
        }
        if let expires = date(holder?["expiry"]), expires <= environment.now() {
            return failed("agy", "Antigravity's sign-in needs renewing. It does that itself with its next message.", environment)
        }
        // Google answers by client: only the CLI's own name gets every group
        // of models, the separate Gemini quota included.
        let version = environment.shell("agy --version 2>/dev/null")?.split(whereSeparator: \.isNewline).last
            .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil ? $0 : nil }
        let headers = ["User-Agent": "antigravity/cli/\(version ?? "1.5.5") darwin/arm64"]
        let metadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
        let base = "https://cloudcode-pa.googleapis.com/v1internal:"
        guard let assist = request(base + "loadCodeAssist", bearer: token, headers: headers, body: ["metadata": metadata]) else { return failed("agy", "Invalid request.", environment) }
        let account = environment.http(assist)
        guard let account, account.status == 200, let profile = object(account.body) else {
            return failed("agy", problem(status: account?.status, service: "Google", signIn: "Send a message in Antigravity to renew it."), environment)
        }
        let project = profile["cloudaicompanionProject"] as? String ?? (profile["cloudaicompanionProject"] as? [String: Any])?["id"] as? String
        let plan = (profile["paidTier"] as? [String: Any])?["name"] as? String ?? (profile["currentTier"] as? [String: Any])?["name"] as? String
        let body: [String: Any] = project.map { ["project": $0] } ?? [:]
        // The summary is served by the daily host; the main one is the fallback.
        for host in ["https://daily-cloudcode-pa.googleapis.com/v1internal:", base] {
            guard let request = request(host + "retrieveUserQuotaSummary", bearer: token, headers: headers, body: body),
                  let answer = environment.http(request), answer.status == 200, let summary = object(answer.body)
            else { continue }
            var usage = parseAntigravity(summary, now: environment.now())
            usage.plan = plan
            return usage
        }
        var usage = failed("agy", "Google did not report this account's quota.", environment)
        usage.plan = plan
        return usage
    }

    static func parseAntigravity(_ body: [String: Any], now: Date) -> AccountUsage {
        let summary = body["response"] as? [String: Any] ?? body["summary"] as? [String: Any] ?? body
        var groups: [AccountUsageGroup] = []
        for group in (summary["groups"] as? [[String: Any]]) ?? [] {
            let name = group["displayName"] as? String ?? group["name"] as? String
            let limits = ((group["buckets"] as? [[String: Any]]) ?? []).compactMap { bucket -> AccountLimit? in
                guard bucket["disabled"] as? Bool != true,
                      let left = number(bucket["remainingFraction"]) ?? number((bucket["remaining"] as? [String: Any])?["remainingFraction"])
                else { return nil }
                let window = bucket["window"] as? String ?? ""
                let short = window == "weekly" ? "Week" : window.isEmpty ? "Quota" : window
                let title = (bucket["displayName"] as? String)?.replacingOccurrences(of: " Remaining", with: "") ?? (short + " limit")
                let id = bucket["bucketId"] as? String ?? bucket["id"] as? String ?? "\(name ?? "")-\(window)"
                return AccountLimit(id: id, title: title, shortTitle: short, usedPercent: max(0, min(100, (1 - left) * 100)), resetsAt: date(bucket["resetTime"]))
            }
            // The short limit first, then the week, as every agent lists them.
            let ordered = limits.enumerated().sorted { a, b in
                let (first, second) = (a.element.shortTitle == "Week" ? 1 : 0, b.element.shortTitle == "Week" ? 1 : 0)
                return first != second ? first < second : a.offset < b.offset
            }.map(\.element)
            if !ordered.isEmpty { groups.append(AccountUsageGroup(title: name, note: group["description"] as? String, limits: ordered)) }
        }
        return AccountUsage(agent: "agy", showsRemaining: true, groups: groups, fetchedAt: now, problem: groups.isEmpty ? "Google reported no quota for this account." : nil)
    }

    // MARK: Network

    /// Sends one request and waits for the answer. Redirects are not
    /// followed: a sign-in goes to the host it was meant for and no other.
    private static func send(_ request: URLRequest) -> (status: Int, body: Data)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result: (status: Int, body: Data)?
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return result
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
#endif
