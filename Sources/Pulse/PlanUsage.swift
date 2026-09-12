import Foundation

/// 套餐额度来源：Claude（网络 OAuth 接口）或 Codex（本地 jsonl）
enum QuotaSource: String, CaseIterable {
    case claude, codex
}

/// 套餐额度（Claude 来自 Anthropic OAuth usage 接口，与 /usage 页面同源；Codex 来自本地 rollout jsonl）
struct PlanLimitInfo: Identifiable {
    let id: String        // kind: session / weekly_all / weekly_scoped / window_N
    let label: String     // 展示标签（已按语言选好）
    let percentUsed: Int  // 已用百分比 0-100
    let resetsAt: Date?
}

struct PlanUsage {
    let limits: [PlanLimitInfo]
    let fetchedAt: Date
    let source: QuotaSource

    /// 周总额度剩余百分比（菜单栏用）
    var weeklyRemainingPercent: Int? {
        guard let w = limits.first(where: { $0.id == "weekly_all" }) else { return nil }
        return max(0, 100 - w.percentUsed)
    }

    static let sessionWindow: TimeInterval = 5 * 3600
    /// 5 小时窗口重置时刻（无活跃窗口时 nil）
    var sessionResetsAt: Date? { limits.first { $0.id == "session" }?.resetsAt }
    /// 5 小时窗口已用百分比
    var sessionPercentUsed: Int? { limits.first { $0.id == "session" }?.percentUsed }
    /// 剩余秒数（≥0），无窗口或已过期返回 nil
    func sessionRemaining(at now: Date = Date()) -> TimeInterval? {
        guard let r = sessionResetsAt else { return nil }
        let d = r.timeIntervalSince(now)
        return d > 0 ? d : nil
    }
    /// 剩余时间占 5 小时的比例 0...1，无窗口返回 nil
    func sessionRemainingFraction(at now: Date = Date()) -> Double? {
        guard let d = sessionRemaining(at: now) else { return nil }
        return min(1, max(0, d / Self.sessionWindow))
    }
    /// 5 小时窗口剩余额度比例 0...1（圆环用；无窗口返回 nil）
    var sessionQuotaRemainingFraction: Double? {
        guard let used = sessionPercentUsed, sessionResetsAt != nil else { return nil }
        return Double(max(0, 100 - used)) / 100.0
    }
    /// 节奏判断：剩余额度比例 − 剩余时间比例（百分点）。≥0 宽裕；-20...0 偏快；<-20 超速
    enum Pace { case ample, fast, over }
    func sessionPace(at now: Date = Date()) -> Pace? {
        guard let q = sessionQuotaRemainingFraction, let t = sessionRemainingFraction(at: now) else { return nil }
        let diff = (q - t) * 100
        if diff >= 0 { return .ample }
        if diff >= -20 { return .fast }
        return .over
    }
    /// 菜单栏用短格式：剩余 ≥1 小时显示 "1:06"（时:分），<1 小时显示 "38m"，无窗口返回 nil
    func sessionRemainingShort(at now: Date = Date()) -> String? {
        guard let d = sessionRemaining(at: now) else { return nil }
        let total = Int(d.rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        return "\(max(m, 1))m"   // 不足 1 分钟也显示 1m，别显示 0m
    }
    /// 面板用长格式：始终 "H:MM:SS"，如 "1:06:32"、"0:04:09"；无窗口返回 nil
    func sessionRemainingLong(at now: Date = Date()) -> String? {
        guard let d = sessionRemaining(at: now) else { return nil }
        let total = Int(d.rounded(.down))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// 拉取 Claude 套餐用量：复用本机 Claude Code 已登录的 OAuth 凭证（只读 accessToken，绝不碰 refreshToken）。
/// 两级重试：系统代理设置 → 真直连（禁用代理，代理出口被限流/不可用时靠这条）。
enum ClaudeQuotaFetcher {

    static func fetch() -> PlanUsage? {
        guard let token = readAccessToken() else { return nil }
        for mode in [ProxyMode.system, .none] {
            let (r, status) = request(token: token, proxy: mode)
            if let r = r { return r }
            // 429/401/403 是账号级错误，换代理也没用，别再叠加请求（usage 接口限流很敏感）
            if let st = status, st == 429 || st == 401 || st == 403 { return nil }
        }
        return nil
    }

    // MARK: - 凭证

    /// Claude Code 把 OAuth 凭证存在钥匙串「Claude Code-credentials」；fallback 到 ~/.claude/.credentials.json
    private static func readAccessToken() -> String? {
        if let json = keychainCredentials(), let t = parseAccessToken(json) { return t }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: path),
           let s = String(data: data, encoding: .utf8),
           let t = parseAccessToken(s) { return t }
        return nil
    }

    private static func keychainCredentials() -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/security"
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        // 同 PulseApp 单实例锁：先读管道再 wait，避免子进程写阻塞导致死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseAccessToken(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - 请求

    /// 返回 (结果, HTTP 状态码)；网络不通时状态码为 nil
    private static func request(token: String, proxy: ProxyMode) -> (PlanUsage?, Int?) {
        let (data, status) = syncGET(
            urlString: "https://api.anthropic.com/api/oauth/usage",
            headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Content-Type": "application/json",
            ],
            proxy: proxy
        )
        guard let data = data else { return (nil, status) }
        return (parse(data), status)
    }

    private static func parse(_ data: Data) -> PlanUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = obj["limits"] as? [[String: Any]]
        else { return nil }

        let labels: [String: String] = [
            "session": L.t("5-hour window", "5 小时窗口"),
            "weekly_all": L.t("Weekly", "本周全部"),
            "weekly_scoped": L.t("Weekly (scoped)", "本周专属"),
        ]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var infos: [PlanLimitInfo] = []
        for item in limits {
            guard let kind = item["kind"] as? String,
                  var label = labels[kind],
                  let percent = item["percent"] as? Int else { continue }
            // scoped 额度：用接口给的模型名（如 Fable → 「本周 Fable 5」）
            if kind == "weekly_scoped",
               let scope = item["scope"] as? [String: Any],
               let model = scope["model"] as? [String: Any],
               let name = model["display_name"] as? String, !name.isEmpty {
                let zhName = name == "Fable" ? "Fable 5" : name
                label = L.t("Weekly \(name)", "本周 \(zhName)")
            }
            var resets: Date? = nil
            if let s = item["resets_at"] as? String {
                resets = iso.date(from: s) ?? isoPlain.date(from: s)
            }
            infos.append(PlanLimitInfo(id: kind, label: label,
                                       percentUsed: min(max(percent, 0), 100),
                                       resetsAt: resets))
        }
        guard !infos.isEmpty else { return nil }
        // 固定顺序：5小时 → 周全部 → 周Opus
        let order = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]
        infos.sort { (order[$0.id] ?? 9) < (order[$1.id] ?? 9) }
        return PlanUsage(limits: infos, fetchedAt: Date(), source: .claude)
    }
}

// MARK: - 共用网络

enum ProxyMode { case system, none }

/// 同步 GET，只认 200，同时带回状态码；system=跟随系统代理设置，none=禁用代理真直连
private func syncGET(urlString: String, headers: [String: String], proxy: ProxyMode) -> (Data?, Int?) {
    guard let url = URL(string: urlString) else { return (nil, nil) }
    var req = URLRequest(url: url, timeoutInterval: 10)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 10
    switch proxy {
    case .system:
        break
    case .none:
        config.connectionProxyDictionary = [:]
    }
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }

    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    var status: Int?
    let task = session.dataTask(with: req) { data, resp, _ in
        defer { sem.signal() }
        guard let http = resp as? HTTPURLResponse else { return }
        status = http.statusCode
        guard http.statusCode == 200 else { return }
        result = data
    }
    task.resume()
    _ = sem.wait(timeout: .now() + 15)
    return (result, status)
}
