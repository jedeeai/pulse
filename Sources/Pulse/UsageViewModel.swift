import Foundation
import Combine

/// 菜单栏数据源：启动后台全量扫描一次 → 之后用 FSEvents 监听目录，文件变动才增量重扫。
/// 不再定时轮询（原版 Nexus 的事件驱动思路），平时几乎不占 CPU。
final class UsageViewModel: ObservableObject {
    @Published var todayTokens: Int = 0
    @Published var todayByTool: [ToolUsage] = []
    @Published var recent5: [DayUsage] = []
    @Published var dailyMap: [Date: Int] = [:]
    @Published var lastUpdated: Date? = nil
    @Published var isLoading: Bool = true   // 首轮全量未完成时为 true
    @Published var plan: PlanUsage? = nil   // 套餐额度（Claude 网络拉取 / Codex 本地文件，5 分钟一次）
    @Published var panelVisible = false     // 面板展开中才让倒计时卡每秒走字，收起时停
    @Published var quotaSource: QuotaSource = .claude   // 额度来源，UserDefaults 持久化
    @Published var planUnavailable = false  // 当前来源拉取/读取失败或本地无数据

    private let historyDays = 200
    private var watcher: FileWatcher?
    private let scanQueue = DispatchQueue(label: "com.jedee.pulse.scan", qos: .utility)
    private let planQueue = DispatchQueue(label: "com.jedee.pulse.plan", qos: .utility)
    private var isScanning = false
    private var pendingRescan = false
    private var isFetchingPlan = false
    private var planTimer: Timer?

    init() {
        if let raw = UserDefaults.standard.string(forKey: "quotaSource"),
           let src = QuotaSource(rawValue: raw) {
            quotaSource = src
        }
        start()
    }

    func start() {
        // 首轮全量（后台），完成后启动文件监听
        scan { [weak self] in
            self?.startWatching()
        }
        // 套餐额度：启动拉一次，之后每 5 分钟一次
        fetchPlan()
        planTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchPlan()
        }
    }

    /// 切换额度来源：持久化、清空旧值、立即重新拉取
    func setQuotaSource(_ source: QuotaSource) {
        guard quotaSource != source else { return }
        quotaSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "quotaSource")
        plan = nil
        planUnavailable = false
        fetchPlan()
    }

    /// 拉取套餐额度（防重入；失败保留旧值）。Claude 走网络，Codex 读本地文件，都放后台队列。
    func fetchPlan() {
        if isFetchingPlan { return }
        isFetchingPlan = true
        let source = quotaSource
        planQueue.async { [weak self] in
            let r: PlanUsage?
            switch source {
            case .claude: r = ClaudeQuotaFetcher.fetch()
            case .codex: r = CodexQuotaReader.read()
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetchingPlan = false
                if let r = r {
                    // 结果的来源要和当前选中的来源一致才赋值：防止切换瞬间旧请求回来覆盖新来源
                    guard r.source == self.quotaSource else { return }
                    self.plan = r
                    self.planUnavailable = false
                } else if source == self.quotaSource {
                    self.planUnavailable = true
                }
            }
        }
    }

    private func startWatching() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".claude/projects").path,
            home.appendingPathComponent(".codex/sessions").path,
        ].filter { FileManager.default.fileExists(atPath: $0) }
        watcher = FileWatcher(paths: paths) { [weak self] in
            self?.scan(completion: nil)   // 文件变动 → 增量重扫（命中缓存极快）
            DispatchQueue.main.async {
                // Codex 额度来自本地文件，文件变动时顺带刷新一次
                if self?.quotaSource == .codex { self?.fetchPlan() }
            }
        }
        watcher?.start()
    }

    /// 手动刷新（按钮用）
    func refresh() {
        scan(completion: nil)
        fetchPlan()
    }

    /// 扫描：串行化，扫描中再来的请求合并成一次补扫
    private func scan(completion: (() -> Void)?) {
        if isScanning { pendingRescan = true; return }
        isScanning = true
        let days = historyDays
        scanQueue.async { [weak self] in
            let r = UsageScanner.scan(historyDays: days)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.dailyMap = r.dailyCombined
                self.recent5 = r.recent5
                self.todayByTool = r.todayByTool
                self.todayTokens = r.todayTotal
                self.lastUpdated = Date()
                self.isLoading = false
                self.isScanning = false
                completion?()
                if self.pendingRescan {
                    self.pendingRescan = false
                    self.scan(completion: nil)
                }
            }
        }
    }

    var menuBarText: String {
        if isLoading { return "…" }
        var parts: [String] = []
        if let s = plan?.sessionRemainingShort() { parts.append(s) }
        parts.append(UsageViewModel.formatShort(todayTokens))
        if let remain = plan?.weeklyRemainingPercent {
            parts.append(L.t("\(remain)%", "余\(remain)%"))
        }
        return parts.joined(separator: " ")
    }

    /// 菜单栏小圆环用：5 小时窗口剩余比例，无活跃窗口返回 nil
    var menuBarRingFraction: Double? { plan?.sessionQuotaRemainingFraction }   // 圈=额度剩余，字=剩余时间

    /// 紧凑：中文 1.4亿/856万/123；英文 1.2B/176M/8.6M/12K/123
    static func formatShort(_ n: Int) -> String {
        if L.isZh {
            if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 100_000_000) }
            if n >= 10_000 { return String(format: "%.0f万", Double(n) / 10_000) }
            return "\(n)"
        }
        return formatEN(n)
    }

    /// 千分位：1,234,567
    static func formatFull(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 用于工具明细右侧：中文 1.42亿/856万；英文 1.2B/176M/8.6M/12K
    static func formatM(_ n: Int) -> String {
        if L.isZh {
            let yi = Double(n) / 100_000_000
            if yi >= 10 { return String(format: "%.1f亿", yi) }
            if yi >= 1 { return String(format: "%.2f亿", yi) }
            if n >= 10_000 { return String(format: "%.0f万", Double(n) / 10_000) }
            return "\(n)"
        }
        return formatEN(n)
    }

    /// 英文单位：≥1e9 B，≥1e6 M（<10M 保留一位小数），≥1e3 K，否则原数字
    static func formatEN(_ n: Int) -> String {
        let v = Double(n)
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 {
            if v < 10_000_000 { return String(format: "%.1fM", v / 1_000_000) }
            return String(format: "%.0fM", v / 1_000_000)
        }
        if v >= 1_000 { return String(format: "%.0fK", v / 1_000) }
        return "\(n)"
    }
}
