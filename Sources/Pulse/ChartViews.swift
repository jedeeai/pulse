import SwiftUI

// 固定尺寸常量（面板宽 280，外层 padding 13，卡片 padding 12 → 卡片内容宽 230）
// 不使用 GeometryReader：避免 SwiftUI 布局循环导致 CPU 100%。
enum Metrics {
    static let cardContentW: CGFloat = 230
    static let yAxisW: CGFloat = 26
    static let yGap: CGFloat = 4
    static var lineW: CGFloat { cardContentW - yAxisW - yGap }  // 折线区宽 155
    static let chartH: CGFloat = 44
    static let labelH: CGFloat = 14

    static let heatCols = 7
    static let heatGap: CGFloat = 4
    static var heatCell: CGFloat { (cardContentW - heatGap * CGFloat(heatCols - 1)) / CGFloat(heatCols) } // 23
}

/// 近 N 日折线趋势图（固定尺寸，左侧亿/万纵坐标，点与底部星期严格对齐）。
struct TrendChartView: View {
    let data: [DayUsage]
    var accent: Color = .blue

    private let inset: CGFloat = 10

    // 纵轴单位：中文按当期最大值自动选亿/万；英文按当期最大值自动选 B/M/K
    private var maxTokens: Double { Double(data.map { $0.tokens }.max() ?? 0) }
    private var unitDiv: Double {
        if L.isZh { return maxTokens >= 100_000_000 ? 100_000_000 : 10_000 }
        if maxTokens >= 1_000_000_000 { return 1_000_000_000 }
        if maxTokens >= 1_000_000 { return 1_000_000 }
        return 1_000
    }
    private var unitLabel: String {
        if L.isZh { return maxTokens >= 100_000_000 ? "亿" : "万" }
        if maxTokens >= 1_000_000_000 { return "B" }
        if maxTokens >= 1_000_000 { return "M" }
        return "K"
    }
    private var topUnits: Double { max(ceil(maxTokens / unitDiv), 1) }
    private var scale: Double { topUnits * unitDiv }

    private func px(_ i: Int) -> CGFloat {
        guard data.count > 1 else { return Metrics.lineW / 2 }
        return inset + (Metrics.lineW - 2 * inset) * CGFloat(i) / CGFloat(data.count - 1)
    }
    private func py(_ v: Int) -> CGFloat {
        Metrics.chartH - CGFloat(Double(v) / scale) * (Metrics.chartH - 6) - 3
    }
    private var pts: [CGPoint] { data.indices.map { CGPoint(x: px($0), y: py(data[$0].tokens)) } }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.yGap) {
            // 纵坐标（亿/万）
            VStack(alignment: .trailing, spacing: 0) {
                Text(fmtM(topUnits) + unitLabel)
                Spacer()
                Text(fmtM(topUnits / 2) + unitLabel)
                Spacer()
                Text("0" + unitLabel)
            }
            .font(.system(size: 7, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: Metrics.yAxisW, height: Metrics.chartH)

            VStack(spacing: 3) {
                ZStack {
                    // 网格线
                    ForEach([0.0, 0.5], id: \.self) { frac in
                        Path { p in
                            let y = (Metrics.chartH - 6) * CGFloat(frac) + 3
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: Metrics.lineW, y: y))
                        }
                        .stroke(.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    }
                    // 渐变填充
                    Path { p in
                        guard let f = pts.first else { return }
                        p.move(to: CGPoint(x: f.x, y: Metrics.chartH))
                        p.addLine(to: f)
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                        if let l = pts.last { p.addLine(to: CGPoint(x: l.x, y: Metrics.chartH)) }
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [accent.opacity(0.30), accent.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    // 折线
                    Path { p in
                        guard let f = pts.first else { return }
                        p.move(to: f)
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // 端点
                    ForEach(pts.indices, id: \.self) { i in
                        Circle().fill(.white).frame(width: 5, height: 5)
                            .overlay(Circle().stroke(accent, lineWidth: 1.5))
                            .position(pts[i])
                    }
                }
                .frame(width: Metrics.lineW, height: Metrics.chartH)

                // 横坐标（同 x 公式 → 对齐）
                ZStack(alignment: .topLeading) {
                    ForEach(data.indices, id: \.self) { i in
                        Text(Self.weekday(data[i].date))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: px(i), y: Metrics.labelH / 2)
                    }
                }
                .frame(width: Metrics.lineW, height: Metrics.labelH)
            }
        }
    }

    private func fmtM(_ m: Double) -> String {
        if m >= 10 { return String(format: "%.0f", m) }
        return (m == m.rounded()) ? String(format: "%.0f", m) : String(format: "%.1f", m)
    }
    static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.isZh ? "zh_CN" : "en_US")
        f.dateFormat = "EEE"
        return f.string(from: d)
    }
}

/// 横版月历热力图（固定 cell 尺寸，周一→周日，未来日期虚线框，可翻月）。
struct MonthHeatmapView: View {
    let dailyMap: [Date: Int]
    @Binding var monthOffset: Int
    var base: Color = Color(red: 0.16, green: 0.49, blue: 0.96)

    private let cal = Calendar.current
    private var weekHeads: [String] { L.isZh ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"] }
    private var cell: CGFloat { Metrics.heatCell }
    private var gap: CGFloat { Metrics.heatGap }

    private var monthStart: Date {
        let b = cal.date(byAdding: .month, value: monthOffset, to: Date()) ?? Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: b)) ?? b
    }
    private var daysInMonth: Int { cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30 }
    private var leadingBlanks: Int { (cal.component(.weekday, from: monthStart) + 5) % 7 }
    private var monthMax: Int {
        var m = 1
        for d in 0..<daysInMonth {
            if let day = cal.date(byAdding: .day, value: d, to: monthStart) {
                m = max(m, dailyMap[cal.startOfDay(for: day)] ?? 0)
            }
        }
        return m
    }
    private var rowCount: Int { Int(ceil(Double(leadingBlanks + daysInMonth) / 7.0)) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                arrow("chevron.left") { monthOffset -= 1 }
                Spacer()
                Text(monthTitle).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                arrow("chevron.right", enabled: monthOffset < 0) { if monthOffset < 0 { monthOffset += 1 } }
            }
            // 星期表头
            HStack(spacing: gap) {
                ForEach(weekHeads.indices, id: \.self) { i in
                    Text(weekHeads[i])
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: cell)
                }
            }
            // 日期格
            ForEach(0..<rowCount, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<7, id: \.self) { c in
                        let slot = r * 7 + c
                        if slot < leadingBlanks || slot >= leadingBlanks + daysInMonth {
                            Color.clear.frame(width: cell, height: cell)
                        } else {
                            cellView(slot - leadingBlanks)
                        }
                    }
                }
            }
        }
        .frame(width: Metrics.cardContentW)
    }

    @ViewBuilder
    private func cellView(_ dayNum: Int) -> some View {
        let day = cal.date(byAdding: .day, value: dayNum, to: monthStart) ?? monthStart
        let isFuture = cal.startOfDay(for: day) > cal.startOfDay(for: Date())
        let v = dailyMap[cal.startOfDay(for: day)] ?? 0
        if isFuture {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                .frame(width: cell, height: cell)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color(v))
                .frame(width: cell, height: cell)
        }
    }

    private func color(_ v: Int) -> Color {
        if v <= 0 { return Color.black.opacity(0.07) }
        let t = Double(v) / Double(monthMax)
        let level = t > 0.66 ? 1.0 : (t > 0.33 ? 0.72 : (t > 0.1 ? 0.48 : 0.28))
        return base.opacity(level)
    }

    private func arrow(_ name: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary.opacity(0.7) : Color.primary.opacity(0.2))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        if L.isZh {
            f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy 年 M 月"
        } else {
            f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMMM yyyy"
        }
        return f.string(from: monthStart)
    }
}
