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
            weeklyResetsAt: weekly.resetsAt ?? all[org]?.weeklyResetsAt
        )
        saveCache(all)
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
