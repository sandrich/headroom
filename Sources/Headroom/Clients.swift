import Foundation

// MARK: - Claude plan limits

struct LimitEntry: Identifiable {
    var id: String
    var name: String
    var percent: Double
    var resetsAt: Date?
    /// Length of the window, used to draw the pace marker.
    var window: TimeInterval?
    var note: String?
}

struct ClaudeLimits {
    var session: LimitEntry?
    var weekly: LimitEntry?
    var model: LimitEntry?
    var all: [LimitEntry]
    var plan: String?
    var fetchedAt: Date
}

enum ClientError: LocalizedError {
    case notLoggedIn(String)
    /// The tool is not installed or has no account; the UI hides that provider.
    case notConfigured
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let m): return m
        case .notConfigured: return "Not set up"
        case .http(401): return "Token expired, will retry"
        case .http(429): return "Rate limited, backing off"
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Unexpected response"
        }
    }
}

private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 15
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c)
}()

private func getJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw ClientError.http(code) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.badResponse }
    return json
}

/// Reads plan limits with the OAuth token Claude Code keeps in the login keychain.
/// The token is never refreshed or stored here; Claude Code owns its rotation.
final class ClaudeLimitsClient {
    private struct Creds { var token: String; var expiresAt: Date?; var plan: String? }

    private func credentials() -> Creds? {
        guard let out = runProcess("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
              out.status == 0,
              let json = try? JSONSerialization.jsonObject(with: out.output) as? [String: Any],
              let oauth = json.dict("claudeAiOauth"),
              let token = oauth.string("accessToken") else { return nil }
        let exp = oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(token: token, expiresAt: exp, plan: Self.planName(oauth.string("subscriptionType"), oauth.string("rateLimitTier")))
    }

    private static func planName(_ sub: String?, _ tier: String?) -> String? {
        guard let sub else { return nil }
        var name = sub.prefix(1).uppercased() + sub.dropFirst()
        if let tier, let r = tier.range(of: #"\d+x"#, options: .regularExpression) { name += " " + tier[r] }
        return name
    }

    func fetch() async throws -> ClaudeLimits {
        guard let creds = credentials() else { throw ClientError.notConfigured }
        if let exp = creds.expiresAt, exp < Date() { throw ClientError.notLoggedIn("Token expired, run Claude Code to refresh") }

        let json = try await getJSON(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(creds.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "claude-code/2.1 headroom",
        ])

        var result = ClaudeLimits(all: [], plan: creds.plan, fetchedAt: Date())
        let limits = json["limits"] as? [[String: Any]] ?? []
        let shares = json["weekly_scoped_shares"] as? [[String: Any]] ?? []

        for (i, l) in limits.enumerated() {
            let kind = l.string("kind") ?? "limit"
            let scopeName = l.dict("scope")?.dict("model")?.string("display_name")
                ?? l.dict("scope")?.dict("surface")?.string("display_name")
            var entry = LimitEntry(id: "\(kind)-\(i)", name: kind, percent: l.double("percent") ?? 0,
                                   resetsAt: ISO.parse(l.string("resets_at")))
            switch kind {
            case "session":
                entry.name = "Session (5h)"
                entry.window = 5 * 3600
                result.session = entry
            case "weekly_all":
                entry.name = "Weekly"
                entry.window = 7 * 86400
                result.weekly = entry
            default:
                entry.name = "Weekly " + (scopeName ?? kind.replacingOccurrences(of: "_", with: " "))
                entry.window = kind.hasPrefix("weekly") ? 7 * 86400 : nil
                if let share = shares.first(where: { $0.int("limit_index") == i }),
                   let used = share.double("used_percent_of_weekly"), let allow = share.double("allowance_percent_of_weekly") {
                    entry.note = "\(Int(used))% of weekly used, \(Int(allow))% allowed"
                }
                if result.model == nil || scopeName?.localizedCaseInsensitiveContains("fable") == true {
                    result.model = entry
                }
            }
            result.all.append(entry)
        }

        // Older response shape without the `limits` array.
        if result.session == nil, let fh = json.dict("five_hour") {
            let e = LimitEntry(id: "five_hour", name: "Session (5h)", percent: fh.double("utilization") ?? 0,
                               resetsAt: ISO.parse(fh.string("resets_at")), window: 5 * 3600)
            result.session = e
            result.all.insert(e, at: 0)
        }
        if result.weekly == nil, let sd = json.dict("seven_day") {
            let e = LimitEntry(id: "seven_day", name: "Weekly", percent: sd.double("utilization") ?? 0,
                               resetsAt: ISO.parse(sd.string("resets_at")), window: 7 * 86400)
            result.weekly = e
            result.all.append(e)
        }
        return result
    }
}

// MARK: - Grok plan usage

struct GrokPlan {
    var percent: Double
    var periodStart: Date?
    var periodEnd: Date?
    var periodName: String
    var products: [(name: String, percent: Double)]
    var fetchedAt: Date
}

/// Reads Grok credit usage with the token the grok CLI stores in ~/.grok/auth.json.
/// When the token has expired, `grok models` is run once to let the CLI refresh it
/// (the CLI owns the file and its lock; this client never writes it).
final class GrokClient {
    private let grokHome = homeDir.appendingPathComponent(".grok")
    private var lastRefresh: Date?

    private func auth() -> (key: String, expires: Date?)? {
        guard let data = try? Data(contentsOf: grokHome.appendingPathComponent("auth.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for case let entry as [String: Any] in json.values {
            if let key = entry.string("key"), !key.isEmpty { return (key, ISO.parse(entry.string("expires_at"))) }
        }
        return nil
    }

    private func refreshToken() async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        lastRefresh = Date()
        let bin = grokHome.appendingPathComponent("bin/grok").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        await Task.detached(priority: .utility) {
            runProcess(bin, ["models"], timeout: 45, captureOutput: false)
        }.value
    }

    func fetch() async throws -> GrokPlan {
        guard var a = auth() else { throw ClientError.notConfigured }
        if let exp = a.expires, exp < Date().addingTimeInterval(60) {
            await refreshToken()
            a = auth() ?? a
        }
        do {
            return try await request(a.key)
        } catch ClientError.http(401) {
            await refreshToken()
            guard let fresh = auth() else { throw ClientError.notConfigured }
            do {
                return try await request(fresh.key)
            } catch ClientError.http(let code) where [401, 402, 403, 404].contains(code) {
                // Logged in but no plan with billing access.
                throw ClientError.notConfigured
            }
        } catch ClientError.http(let code) where [402, 403, 404].contains(code) {
            throw ClientError.notConfigured
        }
    }

    private func request(_ key: String) async throws -> GrokPlan {
        let json = try await getJSON(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
            "User-Agent": "grok-cli headroom",
        ])
        guard let c = json.dict("config") else { throw ClientError.badResponse }
        let period = c.dict("currentPeriod")
        let type = (period?.string("type") ?? "").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "").lowercased()
        let products = (c["productUsage"] as? [[String: Any]] ?? []).compactMap { p -> (String, Double)? in
            guard let n = p.string("product") else { return nil }
            return (n, p.double("usagePercent") ?? 0)
        }
        return GrokPlan(percent: c.double("creditUsagePercent") ?? 0,
                        periodStart: ISO.parse(period?.string("start") ?? c.string("billingPeriodStart")),
                        periodEnd: ISO.parse(period?.string("end") ?? c.string("billingPeriodEnd")),
                        periodName: type.isEmpty ? "period" : type,
                        products: products, fetchedAt: Date())
    }
}

// MARK: - AWS Bedrock usage

/// Which AWS profile and regions to read Bedrock metrics from.
struct BedrockConfig: Equatable {
    /// nil means the AWS CLI's default credential chain.
    var profile: String?
    var regions: [String]
    /// Set by the user rather than guessed from ~/.aws; guessed configs that fail are hidden instead of shown as errors.
    var explicit = false

    var key: String { "\(profile ?? "")|\(regions.joined(separator: ","))" }
    var label: String { ([profile ?? "default"] + regions).joined(separator: " · ") }
}

struct BedrockUsage {
    /// Claude token counts per UTC hour and Bedrock model id (e.g. `au.anthropic.claude-sonnet-5`).
    var hours: [Int: [String: Agg]]
    var config: BedrockConfig
    var fetchedAt: Date
}

/// Reads account-wide Claude usage on Bedrock from the `AWS/Bedrock` CloudWatch metrics, through the AWS CLI
/// so SSO, credential_process and every other credential source work exactly as they do in a terminal.
/// Hourly sums are cached per region so models that went quiet keep their history.
final class BedrockClient {
    private struct Cache: Codable {
        var key = ""
        var regions: [String: [Int: [String: Agg]]] = [:]
    }

    private static let metrics = ["InputTokenCount", "OutputTokenCount", "CacheReadInputTokenCount", "CacheWriteInputTokenCount", "Invocations"]
    private let cacheFile = appSupportDir.appendingPathComponent("bedrock-cloudwatch.json")
    private var cache: Cache?

    private var awsCLI: String? {
        ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/local/aws-cli/aws", "/usr/bin/aws"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Settings first, then the environment (when launched from a terminal), then ~/.aws/config.
    static func config() -> BedrockConfig? {
        let env = ProcessInfo.processInfo.environment
        let configFile = env["AWS_CONFIG_FILE"].map { URL(fileURLWithPath: $0) } ?? homeDir.appendingPathComponent(".aws/config")
        let profiles = parseProfiles((try? String(contentsOf: configFile, encoding: .utf8)) ?? "")
        let hasCredentials = FileManager.default.fileExists(atPath: homeDir.appendingPathComponent(".aws/credentials").path)

        let setProfile = UserDefaults.standard.string(forKey: Prefs.bedrockProfile).flatMap { $0.isEmpty ? nil : $0 }
        let profile = setProfile ?? env["AWS_PROFILE"] ?? (profiles["default"] != nil || profiles.count != 1 ? nil : profiles.keys.first)
        guard setProfile != nil || env["AWS_PROFILE"] != nil || !profiles.isEmpty || hasCredentials else { return nil }

        let setRegions = (UserDefaults.standard.string(forKey: Prefs.bedrockRegions) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let profileRegion: String? = profiles[profile ?? "default"] ?? nil
        let fallback = env["AWS_REGION"] ?? env["AWS_DEFAULT_REGION"] ?? profileRegion
        let regions = setRegions.isEmpty ? (fallback.map { [$0] } ?? []) : setRegions
        return BedrockConfig(profile: profile, regions: regions, explicit: setProfile != nil || !setRegions.isEmpty)
    }

    /// Profile name to region from an AWS config file (`[default]` and `[profile name]` sections).
    private static func parseProfiles(_ text: String) -> [String: String?] {
        var out: [String: String?] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                current = name == "default" ? "default" : name.hasPrefix("profile ") ? String(name.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil
                if let current, out[current] == nil { out[current] = .some(nil) }
            } else if let current, let eq = line.firstIndex(of: "="),
                      line[..<eq].trimmingCharacters(in: .whitespaces) == "region" {
                out[current] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    func fetch() async throws -> BedrockUsage {
        guard let cli = awsCLI, let config = Self.config() else { throw ClientError.notConfigured }
        guard !config.regions.isEmpty else { throw ClientError.notLoggedIn("No AWS region set, choose one under Settings > AWS Bedrock") }

        if cache == nil {
            cache = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
        }
        if cache!.key != config.key { cache = Cache(key: config.key) }

        var firstError: Error?
        var succeeded = 0
        for region in config.regions {
            do {
                let fresh = try await Task.detached(priority: .utility) { try Self.query(cli, profile: config.profile, region: region) }.value
                var merged = cache!.regions[region] ?? [:]
                fresh.forEach { merged[$0.key] = $0.value }
                let minHour = Int(Date().timeIntervalSince1970 / 3600) - Ledger.retentionDays * 24
                cache!.regions[region] = merged.filter { $0.key >= minHour }
                succeeded += 1
            } catch {
                firstError = firstError ?? error
            }
        }
        // With every region failing there is nothing new to show; surface the error (the UI keeps the last values).
        if let firstError, succeeded == 0 { throw firstError }
        if let data = try? JSONEncoder().encode(cache!) { try? data.write(to: cacheFile, options: .atomic) }

        var hours: [Int: [String: Agg]] = [:]
        for byHour in cache!.regions.values {
            for (h, byModel) in byHour {
                for (m, a) in byModel { hours[h, default: [:]][m, default: Agg(calls: 0)].add(a) }
            }
        }
        return BedrockUsage(hours: hours, config: config, fetchedAt: Date())
    }

    /// One GetMetricData call per region: a SEARCH over every model id, hourly sums for the last 30 days.
    private static func query(_ cli: String, profile: String?, region: String) throws -> [Int: [String: Agg]] {
        let names = metrics.map { "MetricName=\"\($0)\"" }.joined(separator: " OR ")
        let queries: [[String: Any]] = [[
            "Id": "bedrock",
            "Expression": "SEARCH('{AWS/Bedrock,ModelId} (\(names))', 'Sum', 3600)",
            "Label": "${PROP('Dim.ModelId')}|${PROP('MetricName')}",
            "ReturnData": true,
        ]]
        let queryJSON = String(data: try JSONSerialization.data(withJSONObject: queries), encoding: .utf8)!
        let now = Date()
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.up) * 3600)
        let start = end.addingTimeInterval(-Double(Ledger.retentionDays) * 86400)
        let iso = ISO8601DateFormatter()

        var args = ["cloudwatch", "get-metric-data", "--region", region,
                    "--start-time", iso.string(from: start), "--end-time", iso.string(from: end),
                    "--metric-data-queries", queryJSON, "--output", "json", "--no-cli-pager"]
        if let profile { args += ["--profile", profile] }

        guard let out = runProcess(cli, args, timeout: 60, captureErrors: true) else { throw ClientError.notConfigured }
        guard out.status == 0 else { throw cliError(String(decoding: out.errors, as: UTF8.self), profile: profile) }
        guard let json = try? JSONSerialization.jsonObject(with: out.output) as? [String: Any] else { throw ClientError.badResponse }
        return parse(json)
    }

    static func parse(_ json: [String: Any]) -> [Int: [String: Agg]] {
        var hours: [Int: [String: Agg]] = [:]
        for r in json["MetricDataResults"] as? [[String: Any]] ?? [] {
            let parts = (r.string("Label") ?? "").components(separatedBy: "|")
            guard parts.count == 2 else { continue }
            let model = parts[0], metric = parts[1]
            let lower = model.lowercased()
            guard lower.contains("claude") || lower.contains("anthropic") else { continue }
            let stamps = r["Timestamps"] as? [String] ?? []
            let values = r["Values"] as? [NSNumber] ?? []
            for (ts, v) in zip(stamps, values) {
                guard let date = ISO.parse(ts) else { continue }
                let n = v.intValue
                var a = Agg(calls: 0)
                switch metric {
                case "InputTokenCount": a.input = n
                case "OutputTokenCount": a.output = n
                case "CacheReadInputTokenCount": a.cacheRead = n
                case "CacheWriteInputTokenCount": a.cacheWrite5m = n
                case "Invocations": a.calls = n
                default: continue
                }
                hours[Int(date.timeIntervalSince1970 / 3600), default: [:]][model, default: Agg(calls: 0)].add(a)
            }
        }
        return hours
    }

    private static func cliError(_ stderr: String, profile: String?) -> Error {
        let s = stderr.lowercased()
        let login = "aws sso login" + (profile.map { " --profile \($0)" } ?? "")
        if s.contains("sso") && (s.contains("expired") || s.contains("refresh") || s.contains("token")) {
            return ClientError.notLoggedIn("AWS session expired, run \(login)")
        }
        if s.contains("accessdenied") || s.contains("not authorized") {
            return ClientError.notLoggedIn("Missing cloudwatch:GetMetricData permission")
        }
        if s.contains("unable to locate credentials") || s.contains("could not be found") {
            return ClientError.notLoggedIn("No AWS credentials for \(profile ?? "default profile")")
        }
        let line = stderr.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ClientError.notLoggedIn(line.map { String($0.prefix(120)) } ?? "AWS CLI failed")
    }
}
