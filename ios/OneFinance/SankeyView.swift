import SwiftUI

/// The render's Cash flow Sankey: money in by source (left) → one total node (middle) →
/// where it went (right). Drawn with Canvas, following the render's own layout code.
struct SankeyView: View {
    let cashflow: Cashflow

    private struct Node {
        let name: String
        let value: Double
        let color: Color
    }

    private let mid = Color(hex: 0xD9CCF2)  // neutral "total" node
    private let node: CGFloat = 6
    private let gap: CGFloat = 12
    private let minSlot: CGFloat = 26  // room for a two-line label next to a thin band
    private let maxTargets = 6

    private var sources: [Node] {
        cashflow.income.filter { $0.amount > 0 }.map { Node(name: $0.source, value: $0.amount, color: Theme.category($0.source)) }
    }

    /// The biggest destinations; the rest are grouped as "Other" so labels don't collide.
    private var targets: [Node] {
        let sorted = cashflow.outflows.filter { $0.amount > 0 }.sorted { $0.amount > $1.amount }
        var out = sorted.prefix(maxTargets - 1).map { Node(name: $0.to, value: $0.amount, color: Theme.category($0.to)) }
        let rest = sorted.dropFirst(maxTargets - 1)
        if rest.count == 1, let only = rest.first {
            out.append(Node(name: only.to, value: only.amount, color: Theme.category(only.to)))
        } else if !rest.isEmpty {
            out.append(Node(name: "Other", value: rest.reduce(0) { $0 + $1.amount }, color: Theme.category("Other")))
        }
        return out
    }

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            let src = sources, tgt = targets
            let totalIn = src.reduce(0) { $0 + $1.value }
            let totalOut = tgt.reduce(0) { $0 + $1.value }
            let scaleTotal = max(totalIn, totalOut)
            guard scaleTotal > 0 else { return }
            // Points per dollar. Thin bands still get a label-sized slot on the right, so take
            // that room out first and scale the rest.
            var k = (H - gap * CGFloat(max(tgt.count - 1, 0))) / scaleTotal
            for _ in 0..<3 {
                let small = tgt.filter { $0.value * k < minSlot }
                let reserved = CGFloat(small.count) * minSlot
                let bigTotal = tgt.filter { $0.value * k >= minSlot }.reduce(0) { $0 + $1.value }
                let room = H - gap * CGFloat(max(tgt.count - 1, 0)) - reserved
                if bigTotal > 0, room > 0 { k = min(room / bigTotal, (H - gap * CGFloat(max(tgt.count - 1, 0))) / scaleTotal) }
            }
            let midX = (W / 2 - node / 2).rounded()
            let midTop = (H - scaleTotal * k) / 2

            func band(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ h: CGFloat) -> Path {
                let xm = (x0 + x1) / 2
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y0))
                p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: xm, y: y0), control2: CGPoint(x: xm, y: y1))
                p.addLine(to: CGPoint(x: x1, y: y1 + h))
                p.addCurve(to: CGPoint(x: x0, y: y0 + h), control1: CGPoint(x: xm, y: y1 + h), control2: CGPoint(x: xm, y: y0 + h))
                p.closeSubpath()
                return p
            }
            func shade(_ x0: CGFloat, _ x1: CGFloat, _ c0: Color, _ c1: Color) -> GraphicsContext.Shading {
                .linearGradient(Gradient(colors: [c0.opacity(0.55), c1.opacity(0.45)]),
                                startPoint: CGPoint(x: x0, y: 0), endPoint: CGPoint(x: x1, y: 0))
            }
            func label(_ s: String, at p: CGPoint, size: CGFloat, weight: Font.Weight, color: Color, anchor: UnitPoint) {
                let t = Text(s).font(.system(size: size, weight: weight)).monospacedDigit().foregroundColor(color)
                ctx.draw(t, at: p, anchor: anchor)
            }

            // Left: the biggest source at the top, small ones stacked at the bottom (as in the render).
            var midY = midTop
            var leftPos: [(y: CGFloat, h: CGFloat)] = []
            for (i, s) in src.enumerated() {
                let h = s.value * k
                let y: CGFloat = i == 0 ? 0 : H - CGFloat(src.count - i) * 34 + 16
                ctx.fill(band(node, y, midX, midY, h), with: shade(node, midX, s.color, mid))
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: node, height: max(h, 3)), cornerRadius: 2), with: .color(s.color))
                leftPos.append((y, h))
                midY += h
            }

            // Right: destinations.
            var ty: CGFloat = 0
            midY = midTop
            var rightPos: [(y: CGFloat, h: CGFloat)] = []
            for t in tgt {
                let h = t.value * k
                ctx.fill(band(midX + node, midY, W - node, ty, h), with: shade(midX + node, W - node, mid, t.color))
                ctx.fill(Path(roundedRect: CGRect(x: W - node, y: ty, width: node, height: max(h, 2)), cornerRadius: 2), with: .color(t.color))
                rightPos.append((ty, max(h, minSlot)))
                midY += h
                ty += max(h, minSlot) + gap
            }

            // Middle "total" node.
            ctx.fill(Path(roundedRect: CGRect(x: midX, y: midTop, width: node, height: scaleTotal * k), cornerRadius: 2), with: .color(mid))

            // Labels.
            for (i, s) in src.enumerated() {
                if i == 0 {
                    label(s.name, at: CGPoint(x: node + 10, y: 14), size: 13, weight: .medium, color: Color(hex: 0xE9DEFF), anchor: .leading)
                    label(Money.whole(s.value), at: CGPoint(x: node + 10, y: 35), size: 18, weight: .bold, color: .white, anchor: .leading)
                } else {
                    let c = leftPos[i].y + leftPos[i].h / 2
                    label(s.name, at: CGPoint(x: node + 10, y: c - 7), size: 11, weight: .medium, color: Color(hex: 0xD8C8F5), anchor: .leading)
                    label(Money.whole(s.value), at: CGPoint(x: node + 10, y: c + 7), size: 12, weight: .bold, color: .white, anchor: .leading)
                }
            }
            for (i, t) in tgt.enumerated() {
                let c = rightPos[i].y + rightPos[i].h / 2
                let pct = totalIn > 0 ? Int((t.value / totalIn * 100).rounded()) : 0
                label(t.name, at: CGPoint(x: W - node - 8, y: c - 7), size: 11, weight: .medium, color: Color(hex: 0xD8C8F5), anchor: .trailing)
                label("\(Money.whole(t.value)) (\(pct)%)", at: CGPoint(x: W - node - 8, y: c + 7), size: 12, weight: .bold, color: .white, anchor: .trailing)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Cash flow: \(Money.whole(cashflow.totalIn)) in, \(Money.whole(cashflow.spent)) spent")
    }
}
