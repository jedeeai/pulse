import SwiftUI
import AppKit

/// 包装 NSVisualEffectView（备用）。
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blendingMode; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blendingMode
    }
}

/// 玻璃胶囊按钮（浮在蓝色渐变上的半透明白玻璃，hover 高亮）。
struct GlassButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color(red: hovering ? 0.90 : 0.94, green: hovering ? 0.93 : 0.96, blue: hovering ? 0.98 : 0.99),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 菜单栏自绘视图：小圆环 + 文字，塞进 NSStatusBarButton 里替代系统 title/image。
/// 原因：macOS 会把非活动屏幕菜单栏的系统按钮文字/图标统一变淡（多屏时另外几块屏几乎看不清），
/// 自绘视图用写死的满亮度颜色，不受这层变淡影响。点击事件穿透给按钮（hitTest 返回 nil）。
final class MenuBarItemView: NSView {
    var title: String = "…" { didSet { relayout() } }
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var hot: Bool = false { didSet { needsDisplay = true } }

    private let ringSide: CGFloat = 16
    private let ringLineW: CGFloat = 2.6
    private let gap: CGFloat = 4
    private let sidePad: CGFloat = 6
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    /// 整个视图应占的宽度（状态栏 length 用）
    var preferredWidth: CGFloat {
        sidePad + ringSide + gap + textSize.width + sidePad
    }

    private var textSize: NSSize {
        (title as NSString).size(withAttributes: [.font: font])
    }

    private func relayout() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize { NSSize(width: preferredWidth, height: NSView.noIntrinsicMetric) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 点击交给底下的按钮
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private var isDarkMenuBar: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override func draw(_ dirtyRect: NSRect) {
        let fg: NSColor = isDarkMenuBar ? .white : .black
        let midY = bounds.midY

        // 圆环
        let center = NSPoint(x: sidePad + ringSide / 2, y: midY)
        let radius = (ringSide - ringLineW) / 2 - 0.5
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = ringLineW
        fg.withAlphaComponent(0.28).setStroke()
        track.stroke()
        let f = min(max(fraction, 0), 1)
        if f > 0.005 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * f, clockwise: true)
            arc.lineWidth = ringLineW
            arc.lineCapStyle = .round
            (hot ? NSColor(red: 0.95, green: 0.58, blue: 0.16, alpha: 1)
                 : NSColor(red: 0.30, green: 0.60, blue: 1.00, alpha: 1)).setStroke()
            arc.stroke()
        }

        // 文字：按实际包围盒真正垂直居中
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let str = NSAttributedString(string: title, attributes: attrs)
        let box = str.boundingRect(with: NSSize(width: 2000, height: 200), options: [.usesLineFragmentOrigin])
        let x = sidePad + ringSide + gap
        let y = midY - box.height / 2 - box.origin.y
        str.draw(at: NSPoint(x: x, y: y))
    }
}
