import Foundation

/// 单日用量
struct DayUsage: Identifiable {
    let date: Date
    let tokens: Int
    var id: Date { date }
}

/// 单工具今日用量
struct ToolUsage: Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }
}

/// 一次扫描的完整结果
struct ScanResult {
    var dailyCombined: [Date: Int] = [:]
    var recent5: [DayUsage] = []
    var todayByTool: [ToolUsage] = []
    var todayTotal: Int = 0
}

/// 多工具会话扫描（带文件级缓存，避免重复读取未改动文件）。
/// token 口径（全口径，含缓存读，2026-07-14 起与 ccusage Total 一致）：
///   Claude:   input + output + cache_creation + cache_read
///   Codex:    input + output + reasoning（input 已含 cached 部分，不再扣除）
enum UsageScanner {

    // MARK: 文件级缓存（增量）
    /// path -> (mtime, 文件大小, 已读到的 byte offset, 累计每天 token, 已见 key 集合)。
    /// mtime+size 不变 → 直接复用；文件变大 → 从 offset 往后只读新增部分。
    private static var cache: [String: (mtime: Date, size: Int64, offset: Int64, perDay: [Date: Int], seen: Set<String>)] = [:]
    private static let cacheLock = NSLock()

    // 兼容旧探针
    static func todayClaudeTokens() -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        return scanClaude(since: today)[today] ?? 0
    }

    static func recentDays(_ days: Int) -> [DayUsage] {
        scan(historyDays: days).recent5
    }

    /// 主入口
    static func scan(historyDays: Int) -> ScanResult {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let since = cal.date(byAdding: .day, value: -(historyDays - 1), to: today) ?? today

        let perTool: [(name: String, map: [Date: Int])] = [
            ("Claude Code", scanClaude(since: since)),
            ("Codex", scanCodex(since: since)),
        ]

        var result = ScanResult()
        var combined: [Date: Int] = [:]
        var byTool: [ToolUsage] = []
        let recent7Start = cal.date(byAdding: .day, value: -6, to: today) ?? today
        for t in perTool {
            for (d, v) in t.map { combined[d, default: 0] += v }
            let todayV = t.map[today] ?? 0
            // 今日有用量，或最近 7 天用过 → 列出该工具（让 Codex 等即便今日为 0 也可见）
            let recent7 = t.map.filter { $0.key >= recent7Start }.values.reduce(0, +)
            if todayV > 0 || recent7 > 0 {
                byTool.append(ToolUsage(name: t.name, tokens: todayV))
            }
        }
        result.dailyCombined = combined
        result.todayByTool = byTool.sorted { $0.tokens > $1.tokens }
        result.todayTotal = combined[today] ?? 0

        var arr: [DayUsage] = []
        for i in 0..<5 {
            if let d = cal.date(byAdding: .day, value: i - 4, to: today) {
                arr.append(DayUsage(date: d, tokens: combined[d] ?? 0))
            }
        }
        result.recent5 = arr
        return result
    }

    // MARK: 各工具（提供"按行抽取 (key, day, tokens)"的闭包）

    static func scanClaude(since: Date) -> [Date: Int] {
        let dir = home(".claude/projects")
        return scanDir(dir: dir, since: since) { obj, cal in
            guard (obj["type"] as? String) == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String, let date = parseISO(ts) else { return nil }
            let key = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? ""
            let tok = intVal(usage, "input_tokens") + intVal(usage, "output_tokens")
                + intVal(usage, "cache_creation_input_tokens")
                + intVal(usage, "cache_read_input_tokens")
            return (key, cal.startOfDay(for: date), tok)
        }
    }

    static func scanCodex(since: Date) -> [Date: Int] {
        let dir = home(".codex/sessions")
        return scanDir(dir: dir, since: since) { obj, cal in
            guard let p = obj["payload"] as? [String: Any],
                  (p["type"] as? String) == "token_count",
                  let info = p["info"] as? [String: Any],
                  let lu = info["last_token_usage"] as? [String: Any],
                  let ts = obj["timestamp"] as? String, let date = parseISO(ts) else { return nil }
            let key = ts + "|" + String(intVal(lu, "total_tokens"))
            let tok = intVal(lu, "input_tokens")
                + intVal(lu, "output_tokens") + intVal(lu, "reasoning_output_tokens")
            return (key, cal.startOfDay(for: date), tok)
        }
    }

    // MARK: 带缓存的目录扫描（增量读取，活跃大文件只读新增字节）

    /// 遍历 dir 下 jsonl。
    /// - 文件 mtime 与缓存一致 → 直接用缓存，0 解析。
    /// - 文件变大了（追加写入，常见）→ 只从上次读到的 byte offset 往后读新增部分，累加进缓存。
    /// - 文件被改小/重写（少见）→ 整文件重读。
    /// 这样活跃的大文件每轮只解析新追加的几 KB，历史文件永久命中缓存。
    private static func scanDir(dir: URL, since: Date,
                               extract: ([String: Any], Calendar) -> (key: String, day: Date, tokens: Int)?) -> [Date: Int] {
        let fm = FileManager.default
        let cal = Calendar.current
        guard let en = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var total: [Date: Int] = [:]
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            if url.lastPathComponent.contains(".jsonl.deleted.") { continue }
            // 每个文件包一层 autoreleasepool：解析产生的临时对象（Data/dict）处理完即释放，
            // 内存峰值 = 单个最大文件，而非全部文件累加。
            let perDay: [Date: Int] = autoreleasepool { processFile(url, since: since, cal: cal, extract: extract) } ?? [:]
            merge(perDay, into: &total, since: since)
        }
        return total
    }

    /// 处理单个文件，返回该文件「全量每天 token」（窗口过滤在外层 merge 做）。命中缓存则直接返回缓存。
    private static func processFile(_ url: URL, since: Date, cal: Calendar,
                                    extract: ([String: Any], Calendar) -> (key: String, day: Date, tokens: Int)?) -> [Date: Int]? {
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = vals.contentModificationDate else { return nil }
        if mtime < since { return nil } // 文件整体太老，窗口外
        let size = Int64(vals.fileSize ?? 0)
        let path = url.path

        cacheLock.lock()
        let cached = cache[path]
        cacheLock.unlock()

        // 完全没变 → 直接复用，零解析
        if let c = cached, c.mtime == mtime, c.size == size {
            return c.perDay
        }

        // 文件增大（追加写）→ 从上次 offset 续读；否则（重写/变小/首次）从头读
        let canAppend = (cached != nil && size >= cached!.size)
        var perDay = canAppend ? cached!.perDay : [:]
        var seen = canAppend ? cached!.seen : Set<String>()
        let startOffset = canAppend ? cached!.offset : 0

        guard let (added, newOffset) = readNewLines(url: url, from: startOffset) else { return perDay }
        for line in added {
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            guard let (key, day, tok) = extract(obj, cal) else { continue }
            if !key.isEmpty { if seen.contains(key) { continue }; seen.insert(key) }
            perDay[day, default: 0] += tok
        }

        // 只有「今天还可能被追加写」的活跃文件才保留 seen + offset（供下次增量去重）。
        // 历史文件（mtime 在今天之前）不会再变，丢弃 seen 省内存，下次靠 mtime+size 命中即可。
        let today = cal.startOfDay(for: Date())
        let isActive = mtime >= today
        cacheLock.lock()
        if isActive {
            cache[path] = (mtime, size, newOffset, perDay, seen)
        } else {
            cache[path] = (mtime, size, newOffset, perDay, [])
        }
        cacheLock.unlock()
        return perDay
    }

    /// 从 offset 处读取文件，按行切分（只返回完整行），返回 (行数据, 新的 offset)。
    /// 末尾不完整的一行（还没写完）会留到下次。
    private static func readNewLines(url: URL, from offset: Int64) -> (lines: [Data], newOffset: Int64)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: UInt64(offset))
            let data = try fh.readToEnd() ?? Data()
            if data.isEmpty { return ([], offset) }
            let nl = UInt8(ascii: "\n")
            // 找最后一个换行，之后的残行不算（下次再读）
            guard let lastNL = data.lastIndex(of: nl) else {
                return ([], offset) // 没有完整行，等下次
            }
            let complete = data[..<(data.index(after: lastNL))]
            let consumed = Int64(complete.count)
            var lines: [Data] = []
            var start = complete.startIndex
            for i in complete.indices where complete[i] == nl {
                if i > start { lines.append(Data(complete[start..<i])) }
                start = complete.index(after: i)
            }
            return (lines, offset + consumed)
        } catch {
            return nil
        }
    }

    private static func merge(_ src: [Date: Int], into dst: inout [Date: Int], since: Date) {
        for (d, v) in src where d >= since { dst[d, default: 0] += v }
    }

    // MARK: 工具

    private static func home(_ rel: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel, isDirectory: true)
    }
    private static func intVal(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }
    private static let isoWithFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static func parseISO(_ s: String) -> Date? {
        isoWithFrac.date(from: s) ?? isoNoFrac.date(from: s)
    }
}
