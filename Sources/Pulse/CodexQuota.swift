import Foundation

/// 从本地 Codex CLI 会话记录里读套餐额度。
/// Codex 每次请求后会在 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 追加一行
/// `payload.type == "token_count"`，里面 `payload.rate_limits.primary/secondary` 是
/// `{used_percent, window_minutes, resets_at(epoch秒)}`，两者都可能为 null，
/// 有些行 rate_limits 整体为 null（还没收到限额信息）。
/// 纯本地文件读取，不发网络请求，读最新几个文件即可，不需要 UsageScanner 那套增量缓存。
enum CodexQuotaReader {

    /// 命中的一条 token_count 记录：时间戳 + 它的 rate_limits 字典
    private struct Candidate {
        let timestamp: Date
        let rateLimits: [String: Any]
    }

    static func read() -> PlanUsage? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let files = allJSONLFiles(under: dir), !files.isEmpty else { return nil }

        // 按 mtime 降序取最新 8 个文件
        let latest8 = files.sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }.prefix(8)

        var best: Candidate?
        for f in latest8 {
            guard let c = findCandidate(in: f.url) else { continue }
            if best == nil || c.timestamp > best!.timestamp { best = c }
        }
        guard let picked = best else { return nil }

        let now = Date()
        var infos: [PlanLimitInfo] = []
        if let primary = picked.rateLimits["primary"] as? [String: Any],
           let info = toLimitInfo(primary, now: now) {
            infos.append(info)
        }
        if let secondary = picked.rateLimits["secondary"] as? [String: Any],
           let info = toLimitInfo(secondary, now: now) {
            infos.append(info)
        }
        guard !infos.isEmpty else { return nil }

        // 排序：session → weekly_all → 其他
        let order: [String: Int] = ["session": 0, "weekly_all": 1]
        infos.sort { (order[$0.id] ?? 9) < (order[$1.id] ?? 9) }

        // fetchedAt 用记录自身的 timestamp（数据时刻），不是现在时间
        return PlanUsage(limits: infos, fetchedAt: picked.timestamp, source: .codex)
    }

    // MARK: - 文件查找

    private struct FileInfo { let url: URL; let mtime: Date? }

    private static func allJSONLFiles(under dir: URL) -> [FileInfo]? {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var result: [FileInfo] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            result.append(FileInfo(url: url, mtime: vals?.contentModificationDate))
        }
        return result
    }

    /// 从文件最后一行往前找，第一行满足「能解析 JSON、type==token_count、rate_limits 非 null 且 primary 非 null」即命中
    private static func findCandidate(in url: URL) -> Candidate? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rateLimits = payload["rate_limits"] as? [String: Any],
                  rateLimits["primary"] as? [String: Any] != nil,
                  let ts = obj["timestamp"] as? String,
                  let date = parseISO(ts)
            else { continue }
            return Candidate(timestamp: date, rateLimits: rateLimits)
        }
        return nil
    }

    // MARK: - rate_limits 子项 → PlanLimitInfo

    private static func toLimitInfo(_ dict: [String: Any], now: Date) -> PlanLimitInfo? {
        guard let usedPercent = numberVal(dict, "used_percent"),
              let minutes = intVal(dict, "window_minutes") else { return nil }
        let (id, label) = windowLabel(minutes: minutes)
        var percentUsed = min(max(Int(usedPercent.rounded()), 0), 100)

        var resetsAt: Date?
        if let epoch = numberVal(dict, "resets_at") {
            resetsAt = Date(timeIntervalSince1970: epoch)
        }
        // 过期处理：resets_at 已经早于现在 → 窗口已重置但本地没再用过 Codex，本地数据是旧的
        if let r = resetsAt, r < now {
            percentUsed = 0
            resetsAt = nil
        }
        return PlanLimitInfo(id: id, label: label, percentUsed: percentUsed, resetsAt: resetsAt)
    }

    private static func windowLabel(minutes: Int) -> (id: String, label: String) {
        if minutes == 300 {
            return ("session", L.t("5-hour window", "5 小时窗口"))
        }
        if minutes == 10080 || minutes == 10081 {
            return ("weekly_all", L.t("Weekly", "本周全部"))
        }
        if minutes >= 1440 {
            let days = Int((Double(minutes) / 1440.0).rounded())
            return ("window_\(minutes)", L.t("\(days)-day window", "\(days) 天窗口"))
        }
        let hours = Int((Double(minutes) / 60.0).rounded())
        return ("window_\(minutes)", L.t("\(hours)-hour window", "\(hours) 小时窗口"))
    }

    // MARK: - 工具

    private static func numberVal(_ dict: [String: Any], _ key: String) -> Double? {
        (dict[key] as? NSNumber)?.doubleValue
    }
    private static func intVal(_ dict: [String: Any], _ key: String) -> Int? {
        (dict[key] as? NSNumber)?.intValue
    }

    private static let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func parseISO(_ s: String) -> Date? {
        isoWithFrac.date(from: s) ?? isoNoFrac.date(from: s)
    }
}
