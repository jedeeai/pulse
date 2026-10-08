import SwiftUI
import AppKit
import Combine

/// 入口：PULSE_PROBE 走命令行探针；否则启动纯 AppKit 菜单栏 app。
@main
struct Entry {
    static func main() {
        if ProcessInfo.processInfo.environment["PULSE_PROBE"] != nil {
            let r = UsageScanner.scan(historyDays: 200)
            print("PROBE todayTotal=\(r.todayTotal)")
            print("PROBE byTool=\(r.todayByTool.map { "\($0.name):\($0.tokens)" }.joined(separator: ", "))")
            print("PROBE recent5=\(r.recent5.map { $0.tokens })")
            print("PROBE legacy_claude=\(UsageScanner.todayClaudeTokens())")
            if let plan = ClaudeQuotaFetcher.fetch() {
                let s = plan.limits.map { "\($0.id):\($0.percentUsed)%" }.joined(separator: ", ")
                print("PROBE plan=\(s) weeklyRemain=\(plan.weeklyRemainingPercent ?? -1)%")
            } else {
                print("PROBE plan=nil")
            }
            if let codex = CodexQuotaReader.read() {
                let s = codex.limits.map { "\($0.id):\($0.percentUsed)%" }.joined(separator: ", ")
                print("PROBE codexPlan=\(s) fetchedAt=\(codex.fetchedAt)")
            } else {
                print("PROBE codexPlan=nil")
            }
            return
        }
        // 单实例锁：已有 Pulse 在跑就直接退出，避免多实例叠加扫描吃 CPU
        if runningSameExecutableCount() > 1 { return }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// 统计与自己同路径可执行文件的运行实例数（含自己）
    static func runningSameExecutableCount() -> Int {
        let myPath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Pulse"
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        do { try task.run() } catch { return 1 }
        // 必须先读完管道再 waitUntilExit：ps 输出超过管道缓冲区(64KB)时会写阻塞，
        // 先 wait 会和 ps 互相等待，主线程死锁在启动阶段（菜单栏图标永不出现）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        let exeName = (myPath as NSString).lastPathComponent
        var count = 0
        for line in out.split(separator: "\n") {
            if line.contains(exeName) { count += 1 }
        }
        return max(count, 1)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hosting: NSHostingView<PulseMenuContent>!
    private var scrollView: NSScrollView!
    private var footerHosting: NSHostingView<PulseFooter>!
    private var panelContainer: PanelBackgroundView!
    private let vm = UsageViewModel()
    private var cancellables = Set<AnyCancellable>()
    private let itemView = MenuBarItemView()
    private var tickTimer: Timer?
    private var lastMenuTitle = ""
    private var lastRingFraction: Double = -1
    private var lastExpiryRefetch: Date = .distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = ""
            button.target = self
            button.action = #selector(togglePanel)
            // 自绘视图铺满按钮（非活动屏幕菜单栏不会被系统变淡）
            itemView.frame = button.bounds
            itemView.autoresizingMask = [.width, .height]
            button.addSubview(itemView)
        }
        vm.$lastUpdated
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)
        vm.$plan
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateMenuBar()
            }
            .store(in: &cancellables)

        updateMenuBar()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tickTimer!, forMode: .common)

        buildPanel()

        if ProcessInfo.processInfo.environment["PULSE_SHOW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.togglePanel()
            }
        }
    }

    /// 只在标题变化或图标比例变化超过 0.01 时才更新，避免每秒无谓刷新菜单栏
    private func updateMenuBar() {
        let title = vm.menuBarText
        let fraction = vm.menuBarRingFraction ?? 0
        let hot = fraction <= 0.2
        let titleChanged = title != lastMenuTitle
        let ringChanged = abs(fraction - lastRingFraction) > 0.01
        guard titleChanged || ringChanged else { return }
        lastMenuTitle = title
        lastRingFraction = fraction
        itemView.title = title
        itemView.fraction = fraction
        itemView.hot = hot
        statusItem.length = itemView.preferredWidth
        if let b = statusItem.button { itemView.frame = b.bounds }
    }

    /// 每秒走字；5 小时窗口一到点自动重拉数据（限流 60 秒一次）
    private func tick() {
        updateMenuBar()
        if let resetsAt = vm.plan?.sessionResetsAt, resetsAt <= Date(),
           Date().timeIntervalSince(lastExpiryRefetch) > 60 {
            lastExpiryRefetch = Date()
            vm.fetchPlan()
        }
    }

    private func buildPanel() {
        hosting = NSHostingView(rootView: PulseMenuContent(vm: vm))
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear

        // 内容放进 NSScrollView：屏幕矮（如 1080p / 缩放模式）时面板高度钳到屏幕内，超出部分滚动查看
        let document = FlippedDocumentView()
        document.addSubview(hosting)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .automatic
        scroll.horizontalScrollElasticity = .none
        scroll.autoresizingMask = []
        scrollView = scroll

        footerHosting = NSHostingView(rootView: PulseFooter(vm: vm))
        footerHosting.translatesAutoresizingMaskIntoConstraints = true
        footerHosting.wantsLayer = true
        footerHosting.layer?.backgroundColor = .clear
        footerHosting.autoresizingMask = []

        let container = PanelBackgroundView(frame: .zero)
        container.addSubview(scroll)
        container.addSubview(footerHosting)
        container.scrollArea = scroll
        container.footer = footerHosting
        panelContainer = container

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 380),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = container
        panel.appearance = NSAppearance(named: .aqua)
        panel.delegate = self
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        self.panel = panel
    }

    private var isShown = false       // 逻辑展开状态（不依赖 isVisible，动画期间也准确）
    private var isAnimating = false    // 动画进行中，屏蔽重入

    @objc private func togglePanel() {
        if isAnimating { return }
        if isShown { animateOut() } else { animateIn() }
    }

    /// 下拉展开：高度从顶部 1 → 完整，配合淡入
    private func animateIn() {
        guard let panel = panel, !isAnimating else { return }
        isAnimating = true
        isShown = true
        vm.panelVisible = true
        vm.refresh()
        vm.refreshAccounts()

        // 先按内容算好最终尺寸（高度钳到屏幕可用范围内，超出走滚动）+ 定位
        let size = hosting.fittingSize
        let footerH = footerHosting.fittingSize.height
        if size.width > 0, size.height > 0 {
            let maxH = maxPanelHeight()
            let panelH = min(size.height + footerH, maxH)
            hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            scrollView.documentView?.frame = hosting.frame
            panelContainer.footerHeight = footerH
            panel.setContentSize(NSSize(width: size.width, height: panelH))
            panelContainer.needsLayout = true
            panelContainer.layoutSubtreeIfNeeded()
            scrollView.contentView.scroll(to: .zero)   // 文档视图已翻转，zero 即顶部；每次展开回到顶部
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        positionPanel()
        let finalFrame = panel.frame

        var startFrame = finalFrame
        startFrame.size.height = 1
        startFrame.origin.y = finalFrame.maxY - 1
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.savedFrame = finalFrame
            self.isAnimating = false
            self.installOutsideClickMonitor()   // 展开完成后开始监听面板外点击
        })
    }

    // 全局/本地点击监听：点面板外任意处 → 收回。比 resignKey 可靠（borderless panel 不成为 key window）。
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // 其它 app 区域的点击
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.handleOutsideClick()
        }
        // 本 app 内（菜单栏图标除外）的点击：本地 monitor 要原样返回事件
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self, let panel = self.panel else { return event }
            // 点在面板自身窗口内 → 不收回
            if event.window === panel { return event }
            self.handleOutsideClick()
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let g = globalClickMonitor { NSEvent.removeMonitor(g); globalClickMonitor = nil }
        if let l = localClickMonitor { NSEvent.removeMonitor(l); localClickMonitor = nil }
    }

    private func handleOutsideClick() {
        guard isShown, !isAnimating else { return }
        animateOut()
    }

    private var savedFrame: NSRect = .zero

    /// 上收：高度 → 1（收进顶部），配合淡出
    private func animateOut() {
        guard let panel = panel, !isAnimating, isShown else { return }
        isAnimating = true
        isShown = false
        vm.panelVisible = false

        let cur = savedFrame == .zero ? panel.frame : savedFrame
        var endFrame = cur
        endFrame.size.height = 1
        endFrame.origin.y = cur.maxY - 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrame(cur, display: false)  // 复位
            self.panel.alphaValue = 1
            self.isAnimating = false
            self.removeOutsideClickMonitor()   // 收回后停止监听
        })
    }

    private func positionPanel() {
        // 调试模式：固定居中，确保截图能稳定拍到
        if ProcessInfo.processInfo.environment["PULSE_SHOW"] != nil,
           let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let x = vf.midX - panel.frame.width / 2
            let y = vf.midY - panel.frame.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        guard let button = statusItem.button, let btnWindow = button.window else { return }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let rectOnScreen = btnWindow.convertToScreen(rectInWindow)
        let w = panel.frame.width
        var x = rectOnScreen.midX - w / 2
        var y = rectOnScreen.minY - panel.frame.height - 6
        if let screen = btnWindow.screen {
            x = min(x, screen.visibleFrame.maxX - w - 8)
            x = max(x, screen.visibleFrame.minX + 8)
            y = max(y, screen.visibleFrame.minY + 8)   // 兜底：不让面板伸出屏幕底边（Dock 以上）
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 面板在当前屏幕能用的最大高度：状态栏按钮下沿 6pt 起，到 Dock/屏幕底边留 8pt
    private func maxPanelHeight() -> CGFloat {
        if ProcessInfo.processInfo.environment["PULSE_SHOW"] != nil, let screen = NSScreen.main {
            return screen.visibleFrame.height - 16
        }
        guard let button = statusItem.button, let btnWindow = button.window, let screen = btnWindow.screen else {
            return (NSScreen.main?.visibleFrame.height ?? 800) - 16
        }
        let rectOnScreen = btnWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return max(240, rectOnScreen.minY - 6 - (screen.visibleFrame.minY + 8))
    }

    // 收回改用全局点击监听（见 installOutsideClickMonitor），不再依赖 resignKey
}

/// 面板底栏：刷新 / 退出，固定在面板底部不随卡片滚动
struct PulseFooter: View {
    @ObservedObject var vm: UsageViewModel
    var body: some View {
        HStack(spacing: 8) {
            GlassButton(icon: "arrow.clockwise", label: L.t("Refresh", "刷新")) { vm.refresh() }
            GlassButton(icon: "power", label: L.t("Quit", "退出")) { NSApplication.shared.terminate(nil) }
        }
        .padding(.top, 10)
        .padding(.horizontal, 13)
        .padding(.bottom, 13)
        .frame(width: 280)
    }
}

/// 面板背景容器：蓝色柔和渐变（实色，设计决定不用透明度）+ 22pt 连续圆角 + 细白描边
final class PanelBackgroundView: NSView {
    private let gradient = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        gradient.colors = [
            NSColor(red: 0.82, green: 0.90, blue: 0.97, alpha: 1).cgColor,
            NSColor(red: 0.60, green: 0.78, blue: 0.96, alpha: 1).cgColor,
            NSColor(red: 0.40, green: 0.63, blue: 0.93, alpha: 1).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)   // 左上（CALayer 原点在左下）
        gradient.endPoint = CGPoint(x: 1, y: 0)     // 右下
        layer?.insertSublayer(gradient, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 子视图不用 autoresizingMask（展开动画高度从 1 长到满，自动伸缩会算错），由 layout() 按当前 bounds 摆：
    /// 底栏贴底固定高度，滚动区占其上全部
    weak var scrollArea: NSView?
    weak var footer: NSView?
    var footerHeight: CGFloat = 0

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        let fh = min(footerHeight, bounds.height)
        footer?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: fh)
        scrollArea?.frame = NSRect(x: 0, y: fh, width: bounds.width, height: max(0, bounds.height - fh))
    }
}

/// 翻转坐标的滚动文档视图：origin 在左上，scroll(to: .zero) 即回顶
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

struct PulseMenuContent: View {
    @ObservedObject var vm: UsageViewModel
    @State private var monthOffset = 0

    private let accent = Color(red: 0.11, green: 0.40, blue: 0.86)
    private let panelWidth: CGFloat = 280

    // 渐变背景、圆角、描边由 AppKit 容器（PanelBackgroundView）绘制；这里只放可滚动的卡片区
    var body: some View {
        VStack(spacing: 10) {
            header
            todayCard
            sessionCard
            accountCard
            planCard
            trendCard
            heatmapCard
        }
        .padding(.top, 13)
        .padding(.horizontal, 13)
        .frame(width: panelWidth)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            Text("Pulse")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text(L.t("LIVE", "实时")).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 标题行：今日 TOKENS（左） + 更新时间（右）
            HStack(alignment: .firstTextBaseline) {
                Text(L.t("TODAY TOKENS", "今日 TOKENS"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                if let t = vm.lastUpdated {
                    Text("\(Self.timeStr(t)) \(L.t("updated", "更新"))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
            // 总量大数字
            Text(UsageViewModel.formatFull(vm.todayTokens))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.todayTokens)

            // 各工具明细（名称左 + M 值右，同字号）
            if !vm.todayByTool.isEmpty {
                Divider().opacity(0.3).padding(.vertical, 1)
                VStack(spacing: 5) {
                    ForEach(vm.todayByTool) { tool in
                        HStack {
                            Circle().fill(accent.opacity(0.8)).frame(width: 5, height: 5)
                            Text(tool.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary.opacity(0.85))
                            Spacer()
                            Text(UsageViewModel.formatM(tool.tokens))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }

    /// 5 小时窗口倒计时卡：圆环 + 重置时刻/已用%/起点，每秒走字
    private var sessionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if vm.plan == nil {
                HStack(alignment: .firstTextBaseline) {
                    cardTitle(L.t("5-HOUR WINDOW", "5 小时窗口重置"))
                    Spacer()
                }
                Text(planLoadingText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                if vm.panelVisible {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        sessionCardBody(now: ctx.date)
                    }
                } else {
                    sessionCardBody(now: Date())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }

    @ViewBuilder
    private func sessionCardBody(now: Date) -> some View {
        let p = vm.plan
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                cardTitle(L.t("5-HOUR WINDOW", "5 小时窗口重置"))
                Spacer()
                if let p = p {
                    Text("\(Self.dataTimeStr(p.fetchedAt)) \(L.t("updated", "更新"))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            }
            if let p = p, let resetsAt = p.sessionResetsAt,
               p.sessionRemaining(at: now) != nil {
                // 圈 = 这 5 小时的剩余额度比例；环内 = 剩余时间。两个维度对照才看得出「省着用还是放开用」
                let quotaFraction = p.sessionQuotaRemainingFraction ?? 0
                let quotaPct = Int((quotaFraction * 100).rounded())
                let hot = quotaFraction <= 0.2      // 预警看额度，不看时间
                let orange = Color(red: 0.92, green: 0.53, blue: 0.10)
                let ringColor = hot ? orange : accent
                let startedAt = resetsAt.addingTimeInterval(-PlanUsage.sessionWindow)
                let crossesDay = !Calendar.current.isDateInToday(resetsAt)
                let pace = p.sessionPace(at: now)
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    CountdownRing(
                        fraction: quotaFraction,
                        text: p.sessionRemainingLong(at: now) ?? "--:--:--",
                        subtext: L.t("until reset", "后重置"),
                        color: ringColor,
                        size: 84
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(crossesDay
                             ? L.t("Resets tomorrow \(Self.timeStr(resetsAt))", "明天 \(Self.timeStr(resetsAt)) 重置")
                             : L.t("Resets \(Self.timeStr(resetsAt))", "重置 \(Self.timeStr(resetsAt))"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 6) {
                            Text(L.t("\(quotaPct)% left", "额度剩 \(quotaPct)%"))
                                .font(.system(size: 11, weight: hot ? .bold : .medium))
                                .monospacedDigit()
                                .foregroundStyle(hot ? orange : .secondary)
                            if let pace = pace {
                                paceTag(pace, orange: orange)
                            }
                        }
                        Text(L.t("Started \(Self.timeStr(startedAt))", "起于 \(Self.timeStr(startedAt))"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    .fixedSize(horizontal: true, vertical: false)   // 文字列取理想宽度，不被两侧 Spacer 挤成两行
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    CountdownRing(
                        fraction: 0,
                        text: L.t("Idle", "未开始"),
                        subtext: nil,
                        color: accent,
                        size: 84
                    )
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L.t("No active window", "无活跃窗口"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(L.t("Starts on first message", "发一条消息后开始计时"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 节奏标签：额度剩得比时间多=宽裕(蓝)，少 20 点以内=偏快(橙)，超过 20 点=超速(橙加粗)。文字本身就是信息，不靠颜色
    private func paceTag(_ pace: PlanUsage.Pace, orange: Color) -> some View {
        let (label, color, bold): (String, Color, Bool) = {
            switch pace {
            case .ample: return (L.t("On track", "宽裕"), accent, false)
            case .fast:  return (L.t("Fast", "偏快"), orange, false)
            case .over:  return (L.t("Too fast", "超速"), orange, true)
            }
        }()
        return Text(label)
            .font(.system(size: 9, weight: bold ? .bold : .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(color.opacity(0.14), in: Capsule())
    }

    /// Claude 账号切换卡：cswitch 不存在时整张不显示。每行左圆点(●在用/○不在用)，
    /// 在用行底色比其他行深一档（明度区分，不靠色相），非在用行给「切到这个号」蓝色按钮。
    @ViewBuilder
    private var accountCard: some View {
        if AccountSwitch.isAvailable {
            VStack(alignment: .leading, spacing: 7) {
                cardTitle(L.t("CLAUDE ACCOUNT", "CLAUDE 账号"))
                if vm.accounts.isEmpty {
                    Text(L.t("Loading…", "获取中…"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(vm.accounts) { acct in
                            accountRow(acct)
                        }
                    }
                    if vm.accounts.count < 2 {
                        Text(L.t("Log into a second account, then run \"cswitch save\" in Terminal",
                                  "登录第二个号后在终端跑 cswitch save"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                    if let msg = vm.switchMessage {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: vm.switchMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text(msg)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(2)
                        }
                        .foregroundStyle(vm.switchMessageIsError ? warnOrange : accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard())
        }
    }

    private var warnOrange: Color { Color(red: 0.92, green: 0.53, blue: 0.10) }

    /// 单个账号行：左圆点(实心=在用/空心=不在用)，中间邮箱+额度小字，右侧「在用」标签或切换按钮；
    /// 下面通栏一行周额度重置时间（左：哪天几点重置，右：还有多久）
    private func accountRow(_ acct: CSwitchAccount) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            accountRowTop(acct)
            weeklyResetLine(for: acct)
                .padding(.leading, 16)   // 8 圆点 + 8 间距，和邮箱左边对齐
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(acct.active ? accent.opacity(0.12) : Color.white.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func accountRowTop(_ acct: CSwitchAccount) -> some View {
        HStack(spacing: 8) {
            Image(systemName: acct.active ? "circle.fill" : "circle")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(acct.active ? accent : Color.secondary.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(acct.email)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(quotaLine(for: acct))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if acct.active {
                Text(L.t("In use", "在用"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(accent.opacity(0.18), in: Capsule())
            } else {
                switchButton(acct)
            }
        }
    }

    /// 周额度重置行。三种状态：还没到点（时间＋倒计时）/ 已过点（不在用的号缓存的时刻过期了，
    /// 说明周额度已经刷新）/ 没记录。24 小时内重置的倒计时加粗变主色，靠粗细也能看出来。
    private func weeklyResetLine(for acct: CSwitchAccount) -> some View {
        let resetsAt = AccountSwitch.cachedQuota(for: acct.org)?.weeklyResetsAt
        let now = Date()
        let left: String
        var right: String? = nil
        var soon = false
        if let r = resetsAt {
            let day = Self.resetDayStr(r)
            if r > now {
                left = L.t("Weekly resets \(day)", "周额度 \(day) 重置")
                right = Self.untilStr(r.timeIntervalSince(now))
                soon = r.timeIntervalSince(now) < 24 * 3600
            } else {
                left = L.t("Weekly quota reset (\(day))", "周额度已重置（\(day)）")
            }
        } else {
            left = L.t("Weekly reset time not recorded", "周重置时间还没记录")
        }
        return HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 8, weight: .semibold))
            Text(left)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let right = right {
                Text(right)
                    .font(.system(size: 9, weight: soon ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(soon ? accent : Color.secondary.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(.secondary.opacity(0.85))
    }

    /// 重置是哪天几点：今天/明天直说，其余「周X HH:mm」
    static func resetDayStr(_ d: Date) -> String {
        let cal = Calendar.current
        let time = timeStr(d)
        if cal.isDateInToday(d) { return L.t("today \(time)", "今天 \(time)") }
        if cal.isDateInTomorrow(d) { return L.t("tomorrow \(time)", "明天 \(time)") }
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isZh ? "zh_CN" : "en_US")
        f.dateFormat = "EEE HH:mm"
        return f.string(from: d)
    }

    /// 还有多久：≥1 天「2 天 3 小时后」（整天「2 天后」），<1 天「3 小时 20 分后」，<1 小时「20 分钟后」
    static func untilStr(_ t: TimeInterval) -> String {
        let mins = max(1, Int(t / 60))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0, h == 0 { return L.t("in \(d)d", "\(d) 天后") }
        if d > 0 { return L.t("in \(d)d \(h)h", "\(d) 天 \(h) 小时后") }
        if h > 0 { return L.t("in \(h)h \(m)m", "\(h) 小时 \(m) 分后") }
        return L.t("in \(m)m", "\(m) 分钟后")
    }

    private func switchButton(_ acct: CSwitchAccount) -> some View {
        let isSwitchingThis = vm.switchingEmail == acct.email
        let anySwitching = vm.switchingEmail != nil
        return Button(action: { vm.switchAccount(to: acct.email) }) {
            Text(isSwitchingThis ? L.t("Switching…", "切换中…") : L.t("Switch", "切到这个号"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(anySwitching ? accent.opacity(0.45) : accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(anySwitching)
    }

    /// 额度小字：在用账号显示实时的「周剩%·5小时剩%」，其余账号显示上次看到的缓存值
    private func quotaLine(for acct: CSwitchAccount) -> String {
        guard let c = AccountSwitch.cachedQuota(for: acct.org) else {
            return L.t("No quota record yet", "还没有额度记录")
        }
        if acct.active {
            return L.t("Weekly \(c.weeklyRemain)% · 5h \(c.sessionRemain)% left",
                        "周剩 \(c.weeklyRemain)% · 5 小时剩 \(c.sessionRemain)%")
        }
        return L.t("Last seen: weekly \(c.weeklyRemain)% (\(Self.timeStr(c.fetchedAt)))",
                    "上次剩 周 \(c.weeklyRemain)%（\(Self.timeStr(c.fetchedAt))）")
    }

    /// 套餐额度卡：标题随来源变（CLAUDE PLAN / CODEX PLAN），右上角来源切换胶囊；
    /// 三条进度（如 5小时/周全部），≥80% 变橙色加粗（蓝—橙色盲安全对）
    private var planCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center) {
                cardTitle(planCardTitle)
                Spacer()
                SourceToggle(selected: vm.quotaSource) { vm.setQuotaSource($0) }
            }
            if let p = vm.plan {
                HStack {
                    Spacer()
                    Text("\(Self.dataTimeStr(p.fetchedAt)) \(L.t("updated", "更新"))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
                VStack(spacing: 7) {
                    ForEach(p.limits) { limit in
                        planRow(limit)
                    }
                }
            } else {
                Text(planLoadingText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }

    private var planCardTitle: String {
        switch vm.quotaSource {
        case .claude: return L.t("CLAUDE PLAN", "CLAUDE 套餐额度")
        case .codex: return L.t("CODEX PLAN", "CODEX 套餐额度")
        }
    }

    /// plan 为 nil 时两张卡（sessionCard/planCard）共用的文案：
    /// Codex 本地确实没数据 → 提示用一次；其余情况（含 Claude 首次拉取中）保持「获取中…」
    private var planLoadingText: String {
        if vm.quotaSource == .codex, vm.planUnavailable {
            return L.t("No Codex data yet — use Codex once", "还没有 Codex 数据，用一次 Codex 后出现")
        }
        return L.t("Loading…", "获取中…")
    }

    /// 电量条口径：显示「剩 X%」，条越长剩得越多，与菜单栏「余X%」一致；剩 ≤20% 变橙+加粗
    private func planRow(_ limit: PlanLimitInfo) -> some View {
        let remaining = max(0, 100 - limit.percentUsed)
        let hot = remaining <= 20
        let barColor = hot ? Color(red: 0.92, green: 0.53, blue: 0.10) : accent
        return VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text(L.t("\(remaining)% left", "剩 \(remaining)%"))
                    .font(.system(size: 11, weight: hot ? .bold : .semibold))
                    .monospacedDigit()
                    .foregroundStyle(barColor)
                if let r = limit.resetsAt {
                    Text(Self.resetStr(r))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            GeometryReaderlessBar(fraction: Double(remaining) / 100.0,
                                  color: barColor)
        }
    }

    /// 重置时间：今天显示 HH:mm，非今天显示「周X HH:mm」
    static func resetStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isZh ? "zh_CN" : "en_US")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        let time = f.string(from: d)
        return L.t("resets \(time)", "\(time) 重置")
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(L.t("LAST 5 DAYS", "近 5 日趋势"))
            TrendChartView(data: vm.recent5, accent: accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle(L.t("ACTIVITY", "活跃热力图"))
            MonthHeatmapView(dailyMap: vm.dailyMap, monthOffset: $monthOffset, base: accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard())
    }

    private func cardTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }

    /// 数据时刻：当天只显示 HH:mm，非当天带日期（Codex 额度是本地旧记录时能看出是哪天的）
    static func dataTimeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    static func timeStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

/// 倒计时圆环：外圈为剩余比例（越满剩得越多，和电量条口径一致），内圈文字为剩余时间
struct CountdownRing: View {
    let fraction: Double      // 0...1 剩余比例
    let text: String          // 环内主文字，如 "1:06:32" 或 "未开始"
    let subtext: String?      // 环内副文字，如 "后重置"，可 nil
    let color: Color
    let size: CGFloat         // 直径
    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(text)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let subtext = subtext {
                    Text(subtext)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// 固定宽度进度条（不用 GeometryReader，防 SwiftUI 布局循环——见项目故障记录）
struct GeometryReaderlessBar: View {
    let fraction: Double   // 0.0 - 1.0
    let color: Color
    private let width: CGFloat = Metrics.cardContentW
    private let height: CGFloat = 5

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(color.opacity(0.18))
                .frame(width: width, height: height)
            Capsule().fill(color)
                .frame(width: max(height, width * min(max(fraction, 0), 1)), height: height)
        }
        .frame(width: width, height: height)
    }
}

/// 额度来源两段切换器：Claude / Codex 两个并排小胶囊，选中实心 accent 蓝底白字，
/// 未选中浅蓝底深色字（靠明度对比区分，不靠色相，色盲安全）。
struct SourceToggle: View {
    let selected: QuotaSource
    let onSelect: (QuotaSource) -> Void
    private let accent = Color(red: 0.11, green: 0.40, blue: 0.86)

    var body: some View {
        HStack(spacing: 4) {
            pill(.claude, "Claude")
            pill(.codex, "Codex")
        }
    }

    private func pill(_ source: QuotaSource, _ label: String) -> some View {
        let isOn = selected == source
        return Button(action: { onSelect(source) }) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? .white : Color.primary.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(isOn ? accent : accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 实色卡片（原毛玻璃，设计决定不用透明度）
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Color(red: 0.94, green: 0.96, blue: 0.99),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white, lineWidth: 0.6)
            )
    }
}
