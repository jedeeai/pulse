import Foundation

/// Claude 账号切换：包一层 `~/.local/bin/cswitch`（Python，源码在仓库 scripts/cswitch，可选安装）。
/// 原理：cswitch 对调钥匙串「Claude Code-credentials」里的凭证，PlanUsage 下一次读钥匙串
/// 拿到的就是新号的 token。没装 cswitch 时整个功能隐藏。
struct CSwitchAccount: Codable, Identifiable, Equatable {
    let email: String
    let org: String
    let active: Bool
    let plan: String
    var id: String { org }
}

struct CSwitchStatus: Codable, Equatable {
    let active: String
    let accounts: [CSwitchAccount]
}

/// 切换失败原因（cswitch stderr 里的原因，语言跟 Pulse 一致；或本地兜底文案）
struct CSwitchError: Error {
    let message: String
}

/// 单个账号「最后一次看到的额度」快照，UserDefaults 持久化，按组织编号建索引。
struct AcctQuotaSnapshot: Codable {
    let weeklyRemain: Int      // 周剩余百分比
    let sessionRemain: Int     // 5 小时窗口剩余百分比
    let fetchedAt: Date
    var weeklyResetsAt: Date? = nil   // 周额度重置时刻（旧缓存没有这项，解码为 nil）
    var sessionResetsAt: Date? = nil  // 5 小时窗口重置时刻（旧缓存没有，解码为 nil）
    var limited: Bool? = nil          // 探测时是否处于被限状态（unified-status != allowed 或 429）
}

/// 推荐排序里每个账号的「有效额度」＋名次。有效值已按当前时间折算过重置（周/5 小时重置点已过就视为满血）。
struct AcctRecommendation {
    let acct: CSwitchAccount
    let rank: Int                 // 从 1 开始，含不可用的号
    let usable: Bool              // 周额度>0 且 5 小时剩>10% 且没被限
    let hasCache: Bool            // 没缓存的号排最后，usable=false
    let weeklyRemain: Int         // 有效周剩%
    let sessionRemain: Int        // 有效 5 小时剩%
    let weeklyResetsAt: Date?     // 有效周重置时刻（已过点的按 +7 天滚到未来）
    let sessionResetsAt: Date?    // 5 小时窗口重置时刻（已过点则为 nil，因为窗口已刷新）
    let weeklyExhausted: Bool     // 周额度已用完
    let recoverAt: Date?          // 不可用时最早恢复可用的时刻
    let fetchedAt: Date?          // 数据时刻（没缓存为 nil）
}

enum AccountSwitch {
    static let path = NSHomeDirectory() + "/.local/bin/cswitch"
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }

    /// 查询账号列表 + 当前在用的号。只读命令，不会真的切号。
    static func fetchStatus(completion: @escaping (CSwitchStatus?) -> Void) {
        guard isAvailable else { DispatchQueue.main.async { completion(nil) }; return }
        DispatchQueue.global(qos: .utility).async {
            let (out, _, status) = runProcess(path, ["status", "--json"])
            let result = status == 0 ? decodeStatus(out) : nil
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 切到指定邮箱的号。成功返回切换后的最新状态；失败带 stderr 里的原因。
    static func switchTo(email: String, completion: @escaping (Result<CSwitchStatus, CSwitchError>) -> Void) {
        guard isAvailable else {
            DispatchQueue.main.async {
                completion(.failure(CSwitchError(message: L.t("cswitch not found", "cswitch 工具不存在"))))
            }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let (out, err, status) = runProcess(path, ["use", email, "--json"])
            DispatchQueue.main.async {
                if status == 0, let st = decodeStatus(out) {
                    completion(.success(st))
                    return
                }
                let msg = String(data: err, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.failure(CSwitchError(message: (msg?.isEmpty == false ? msg! : nil) ?? L.t("Switch failed", "切换失败"))))
            }
        }
    }

    private static func decodeStatus(_ data: Data) -> CSwitchStatus? {
        try? JSONDecoder().decode(CSwitchStatus.self, from: data)
    }

    /// 起一个子进程，并发读 stdout/stderr 再 waitUntilExit——两个管道任一个输出超过缓冲区都可能
    /// 写阻塞，先各自异步读完再等退出，避免 PulseApp 单实例锁踩过的那种死锁。
    private static func runProcess(_ launchPath: String, _ args: [String]) -> (stdout: Data, stderr: Data, status: Int32) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        // 让 cswitch 的提示语言跟 Pulse 界面一致
        var env = ProcessInfo.processInfo.environment
        env["CSWITCH_LANG"] = L.isZh ? "zh" : "en"
        task.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch {
            return (Data(), Data(), -1)
        }
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        task.waitUntilExit()
        return (outData, errData, task.terminationStatus)
    }

    // MARK: - 每账号额度缓存

    private static let quotaCacheKey = "pulse.acctQuotaCache.v1"

    /// PlanUsage 每次成功拿到 Claude 额度时调用：按 organizationUuid 记一份「周剩%/5小时剩%/时刻」。
    static func recordQuota(_ plan: PlanUsage) {
        guard plan.source == .claude, let org = plan.organizationUuid else { return }
        guard let weekly = plan.limits.first(where: { $0.id == "weekly_all" }),
              let sessionUsed = plan.limits.first(where: { $0.id == "session" })?.percentUsed
        else { return }
        var all = loadCache()
        all[org] = AcctQuotaSnapshot(
            weeklyRemain: max(0, 100 - weekly.percentUsed),
            sessionRemain: max(0, 100 - sessionUsed),
            fetchedAt: plan.fetchedAt,
            // 接口这轮没给重置时刻时沿用上次记的，别把已知的时间冲掉
            weeklyResetsAt: weekly.resetsAt ?? all[org]?.weeklyResetsAt,
            sessionResetsAt: plan.sessionResetsAt ?? all[org]?.sessionResetsAt,
            limited: nil   // usage 接口拿到了数据，说明没被限
        )
        saveCache(all)
    }

    /// TokenProbe 探测到某个账号的实时额度后写入同一份缓存（百分比已是「剩余」口径）。
    /// 重置时刻这轮没给就沿用上次记的。
    static func recordProbe(org: String, weeklyRemain: Int, sessionRemain: Int,
                            weeklyResetsAt: Date?, sessionResetsAt: Date?,
                            limited: Bool, fetchedAt: Date) {
        var all = loadCache()
        all[org] = AcctQuotaSnapshot(
            weeklyRemain: max(0, weeklyRemain),
            sessionRemain: max(0, sessionRemain),
            fetchedAt: fetchedAt,
            weeklyResetsAt: weeklyResetsAt ?? all[org]?.weeklyResetsAt,
            sessionResetsAt: sessionResetsAt ?? all[org]?.sessionResetsAt,
            limited: limited
        )
        saveCache(all)
    }

    // MARK: - 推荐排序

    /// 推荐用哪个号：目标是三个号的周额度都尽量用完、不作废。
    /// 规则：在 5 小时额度没用满的号里，周额度重置时间最早的优先（最早作废的先用）。
    /// 先按当前时间折算缓存（重置点已过 → 视为满血），可用的号按有效周重置时间从早到晚排；
    /// 不可用的排在可用号后面，按最早恢复时刻从早到晚；没缓存的号垫底。
    static func recommendationOrder(accounts: [CSwitchAccount], now: Date) -> [AcctRecommendation] {
        recommendationOrder(accounts: accounts, cache: loadCache(), now: now)
    }

    static func recommendationOrder(accounts: [CSwitchAccount], cache: [String: AcctQuotaSnapshot],
                                    now: Date) -> [AcctRecommendation] {
        struct Item { let rec: AcctRecommendation; let group: Int; let key: Date; let idx: Int }
        var items: [Item] = []
        for (idx, acct) in accounts.enumerated() {
            guard let c = cache[acct.org] else {
                items.append(Item(rec: AcctRecommendation(
                    acct: acct, rank: 0, usable: false, hasCache: false,
                    weeklyRemain: 0, sessionRemain: 0, weeklyResetsAt: nil, sessionResetsAt: nil,
                    weeklyExhausted: false, recoverAt: nil, fetchedAt: nil),
                    group: 2, key: .distantFuture, idx: idx))
                continue
            }
            // 周重置点已过：周额度已刷新，重置时刻按 7 天一轮滚到未来
            var weeklyRemain = c.weeklyRemain
            var weeklyReset = c.weeklyResetsAt
            var weeklyPassed = false
            if let r = weeklyReset, r < now {
                weeklyPassed = true
                weeklyRemain = 100
                var next = r
                while next <= now { next = next.addingTimeInterval(7 * 86400) }
                weeklyReset = next
            }
            // 5 小时窗口重置点已过：窗口已刷新
            var sessionRemain = c.sessionRemain
            var sessionReset = c.sessionResetsAt
            var limited = c.limited ?? false
            if let r = sessionReset, r < now {
                sessionRemain = 100
                sessionReset = nil
                limited = false
            }
            if weeklyPassed && c.weeklyRemain <= 0 { limited = false }
            let exhausted = weeklyRemain <= 0
            let usable = weeklyRemain > 0 && sessionRemain > 10 && !limited
            // 最早恢复时刻：周用完看周重置，否则看 5 小时窗口重置（缺失时退到周重置）
            let recover: Date? = usable ? nil : (exhausted ? weeklyReset : (sessionReset ?? weeklyReset))
            let rec = AcctRecommendation(
                acct: acct, rank: 0, usable: usable, hasCache: true,
                weeklyRemain: weeklyRemain, sessionRemain: sessionRemain,
                weeklyResetsAt: weeklyReset, sessionResetsAt: sessionReset,
                weeklyExhausted: exhausted, recoverAt: recover, fetchedAt: c.fetchedAt)
            items.append(Item(rec: rec, group: usable ? 0 : 1,
                              key: usable ? (weeklyReset ?? .distantFuture) : (recover ?? .distantFuture),
                              idx: idx))
        }
        items.sort { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.key != b.key { return a.key < b.key }
            return a.idx < b.idx
        }
        return items.enumerated().map { i, it in
            let r = it.rec
            return AcctRecommendation(
                acct: r.acct, rank: i + 1, usable: r.usable, hasCache: r.hasCache,
                weeklyRemain: r.weeklyRemain, sessionRemain: r.sessionRemain,
                weeklyResetsAt: r.weeklyResetsAt, sessionResetsAt: r.sessionResetsAt,
                weeklyExhausted: r.weeklyExhausted, recoverAt: r.recoverAt, fetchedAt: r.fetchedAt)
        }
    }

    /// 命令行探针用：同步查账号列表（主线程没跑 RunLoop 时不能用 fetchStatus 的回调版）
    static func fetchStatusBlocking() -> CSwitchStatus? {
        guard isAvailable else { return nil }
        let (out, _, status) = runProcess(path, ["status", "--json"])
        return status == 0 ? decodeStatus(out) : nil
    }

    static func cachedQuota(for org: String) -> AcctQuotaSnapshot? {
        loadCache()[org]
    }

    private static func loadCache() -> [String: AcctQuotaSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: quotaCacheKey),
              let dict = try? JSONDecoder().decode([String: AcctQuotaSnapshot].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveCache(_ dict: [String: AcctQuotaSnapshot]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: quotaCacheKey)
    }
}
