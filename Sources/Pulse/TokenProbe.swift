import Foundation

/// 单个账号的实时额度探测结果（来自 /v1/messages 响应头）
struct TokenProbeResult {
    let org: String
    let fiveHourUtil: Double      // 0~1，5 小时窗口已用比例
    let sevenDayUtil: Double      // 0~1，周额度已用比例
    let fiveHourReset: Date?
    let sevenDayReset: Date?
    let limited: Bool             // 429 或 unified-status != allowed

    /// 剩余百分比 = 100 - round(已用*100)，下限 0
    var sessionRemain: Int { max(0, 100 - Int((fiveHourUtil * 100).rounded())) }
    var weeklyRemain: Int { max(0, 100 - Int((sevenDayUtil * 100).rounded())) }
}

/// 用 ~/.claude/tokens/*.token 里每个号的长期令牌各发一个极小的 /v1/messages 请求（max_tokens=1），
/// 读响应头里的限额信息，让不在用的账号也有实时额度。目录不存在或为空时整个功能静默跳过。
/// 注意：绝不调用 /api/oauth/usage（账号级限流很敏感）。
enum TokenProbe {
    static let dir = NSHomeDirectory() + "/.claude/tokens"

    /// 读出所有令牌（文件内容去掉全部空白字符），目录缺失/为空返回 []
    static func loadTokens() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".token") }.sorted().compactMap { name in
            guard let raw = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { return nil }
            let t = raw.components(separatedBy: .whitespacesAndNewlines).joined()
            return t.isEmpty ? nil : t
        }
    }

    static var isAvailable: Bool { !loadTokens().isEmpty }

    /// 串行探测所有令牌（后台队列调用），失败的号直接跳过
    static func probeAll() -> [TokenProbeResult] {
        loadTokens().compactMap { probeOne(token: $0) }
    }

    private static func probeOne(token: String) -> TokenProbeResult? {
        // 系统代理 → 真直连：只有网络层失败（没拿到 HTTP 响应）才换代理重试一次
        for mode in [ProxyMode.system, .none] {
            guard let http = post(token: token, proxy: mode) else { continue }
            return parse(http)
        }
        return nil
    }

    /// 200 和 429 都读响应头（429 表示撞额度，头里照样有数据），其他状态跳过
    private static func parse(_ http: HTTPURLResponse) -> TokenProbeResult? {
        guard http.statusCode == 200 || http.statusCode == 429 else { return nil }
        func h(_ name: String) -> String? { http.value(forHTTPHeaderField: name) }
        guard let org = h("anthropic-organization-id"), !org.isEmpty,
              let u5 = h("anthropic-ratelimit-unified-5h-utilization").flatMap(Double.init),
              let u7 = h("anthropic-ratelimit-unified-7d-utilization").flatMap(Double.init)
        else { return nil }
        // epoch 秒，取整到分钟（同 ClaudeQuotaFetcher.parse，避免显示 13:59）
        func date(_ name: String) -> Date? {
            guard let e = h(name).flatMap(Double.init) else { return nil }
            return Date(timeIntervalSince1970: (e / 60).rounded() * 60)
        }
        let status = h("anthropic-ratelimit-unified-status") ?? "allowed"
        return TokenProbeResult(
            org: org, fiveHourUtil: u5, sevenDayUtil: u7,
            fiveHourReset: date("anthropic-ratelimit-unified-5h-reset"),
            sevenDayReset: date("anthropic-ratelimit-unified-7d-reset"),
            limited: http.statusCode == 429 || status != "allowed")
    }

    /// 同步 POST，返回 HTTP 响应（网络失败返回 nil）。超时 20 秒。
    private static func post(token: String, proxy: ProxyMode) -> HTTPURLResponse? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "system": "You are Claude Code, Anthropic's official CLI for Claude.",
            "messages": [["role": "user", "content": "hi"]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        if proxy == .none { config.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        var result: HTTPURLResponse?
        let task = session.dataTask(with: req) { _, resp, _ in
            result = resp as? HTTPURLResponse
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 25)
        return result
    }
}
