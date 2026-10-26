import Charts
import SwiftUI

/// Colors and pieces from the dark "vibranium" render (mockups/home-dark.html).
enum Theme {
    static let onyx950 = Color(hex: 0x050408)
    static let onyx900 = Color(hex: 0x0B0910)
    static let onyx800 = Color(hex: 0x13101A)
    static let onyx700 = Color(hex: 0x1C1726)
    static let vib900 = Color(hex: 0x2A0B4D)
    static let vib700 = Color(hex: 0x4B1A8C)
    static let vib500 = Color(hex: 0x8A2BE2)
    static let vib400 = Color(hex: 0xA45CFF)
    static let vib300 = Color(hex: 0xC49BFF)
    static let vib100 = Color(hex: 0xEDE2FF)
    static let text = Color(hex: 0xF4F0FB)
    static let muted = Color(hex: 0x9A90AD)
    static let hairline = Color(hex: 0xA45CFF).opacity(0.16)
    static let positive = Color(hex: 0x2FD39B)
    static let negative = Color(hex: 0xFF6FAE)
    static let over = Color(hex: 0xFF7B6B)
    static let warn = Color(hex: 0xFFB27A)
    static let cardText = Color(hex: 0xDCD3EC)

    /// The phone background: onyx with three soft purple glows.
    static var background: some View {
        ZStack {
            onyx950
            RadialGradient(colors: [vib500.opacity(0.30), .clear], center: UnitPoint(x: 0.85, y: -0.04), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [vib700.opacity(0.25), .clear], center: UnitPoint(x: 0, y: 0.12), startRadius: 0, endRadius: 300)
            RadialGradient(colors: [vib500.opacity(0.22), .clear], center: UnitPoint(x: 0.5, y: 1.08), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }

    static let cardFill = LinearGradient(
        colors: [Color(red: 28 / 255, green: 23 / 255, blue: 38 / 255).opacity(0.92),
                 Color(red: 15 / 255, green: 12 / 255, blue: 21 / 255).opacity(0.92)],
        startPoint: .top, endPoint: .bottom)

    /// Category colors from the render (plus Groceries, Savings and Investing).
    static func category(_ name: String) -> Color {
        switch name {
        case "Utilities": return Color(hex: 0xFFA66B)
        case "Home Rent": return Color(hex: 0xFF8A4C)
        case "Supplies": return Color(hex: 0xFFC48F)
        case "Transportation": return Color(hex: 0xFF6FAE)
        case "Entertainment": return Color(hex: 0x4F8DFF)
        case "Food": return Color(hex: 0x3CC8F5)
        case "Healthcare": return Color(hex: 0xF5C542)
        case "Sports": return Color(hex: 0xB5E35C)
        case "Education": return Color(hex: 0x7A8CFF)
        case "Shopping": return Color(hex: 0xFF7AD9)
        case "Electronics": return Color(hex: 0x5EE6E0)
        case "Travel": return Color(hex: 0x4FB0FF)
        case "Gifts": return Color(hex: 0xFF9A8A)
        case "Savings", "Emergency Fund": return Color(hex: 0x2FD39B)
        case "General Savings": return Color(hex: 0x5EE6E0)
        case "Other Savings": return Color(hex: 0xFF7B7B)
        case "Investing", "Investment": return Color(hex: 0xA45CFF)
        case "Income", "Salary": return Color(hex: 0x2FD39B)
        case "Freelance": return Color(hex: 0x7AE582)
        case "Dividends": return Color(hex: 0xC49BFF)
        case "Other income": return Color(hex: 0x5EE6E0)
        case "Interest": return Color(hex: 0x5EE6E0)
        default: return Color(hex: 0x9AA6C2)
        }
    }
}

extension Theme {
    /// Each pocket's icon (SF Symbols), for the Home pocket cards.
    static func icon(_ name: String) -> String {
        switch name {
        case "Home Rent": return "house.fill"
        case "Utilities": return "bolt.fill"
        case "Food": return "fork.knife"
        case "Supplies": return "cart.fill"
        case "Transportation": return "car.fill"
        case "Healthcare": return "cross.case.fill"
        case "Sports": return "figure.run"
        case "Education": return "graduationcap.fill"
        case "Entertainment": return "film.fill"
        case "Shopping": return "bag.fill"
        case "Electronics": return "desktopcomputer"
        case "Travel": return "airplane"
        case "Gifts": return "gift.fill"
        case "Coffee": return "cup.and.saucer.fill"
        case "Emergency Fund": return "lifepreserver.fill"
        case "General Savings": return "banknote.fill"
        case "Other Savings": return "star.fill"
        case "Investment", "Ready to invest": return "chart.line.uptrend.xyaxis"
        default: return "circle.grid.2x2.fill"
        }
    }
}

/// A pocket's icon in a small rounded rectangle filled with the pocket's color (Home cards).
struct PocketIcon: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: Theme.icon(name))
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.category(name), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .shadow(color: Theme.category(name).opacity(0.45), radius: 4)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// The render's card: dark gradient, hairline border, big corner radius.
struct Card<Content: View>: View {
    var radius: CGFloat = 26
    var padding = EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// The AI card: blue → violet → pink → cyan gradient border.
struct AICard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 30 / 255, green: 24 / 255, blue: 44 / 255).opacity(0.95),
                                        Color(red: 16 / 255, green: 13 / 255, blue: 24 / 255).opacity(0.95)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(LinearGradient(colors: [Color(hex: 0x2B6BFF, opacity: 0.55), Color(hex: 0xA45CFF, opacity: 0.55),
                                                    Color(hex: 0xFF7AD9, opacity: 0.45), Color(hex: 0x00F0D8, opacity: 0.40)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
    }
}

/// "AI SUMMARY" label with the small ring and a right-aligned note.
struct AILabel: View {
    let title: String
    let note: String?

    var body: some View {
        HStack(spacing: 7) {
            AIRing(size: 14, ring: 3.5)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.vib300)
            Spacer()
            if let note {
                Text(note).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.bottom, 8)
    }
}

/// The gradient ring from the render: blue, violet, pink, cyan.
struct AIRing: View {
    var size: CGFloat = 32
    var ring: CGFloat = 7

    var body: some View {
        Circle()
            .strokeBorder(
                AngularGradient(colors: [Color(hex: 0x2B6BFF), Color(hex: 0x7A4DFF), Color(hex: 0xFF7AD9), Color(hex: 0x9B5BFF),
                                         Color(hex: 0x1F6FFF), Color(hex: 0x0A63FF), Color(hex: 0x00B8FF), Color(hex: 0x00F0D8),
                                         Color(hex: 0x19D3FF), Color(hex: 0x0A84FF), Color(hex: 0x2B6BFF)],
                                center: .center),
                lineWidth: ring)
            .frame(width: size, height: size)
            .shadow(color: Color(red: 120 / 255, green: 100 / 255, blue: 1).opacity(0.7), radius: size > 20 ? 5 : 3)
    }
}

/// A rounded pill (the "▲ $2,318 · 2.4%" chip, "Review" buttons).
struct Chip: View {
    let text: String
    var color: Color = Theme.vib300

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.vib500.opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke(Theme.vib400.opacity(0.28), lineWidth: 1))
    }
}

/// Small "Paid" / "Over" tag.
struct Tag: View {
    let text: String
    var over = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(over ? Color(hex: 0xFF9A8A) : Color(hex: 0x7FE8C0))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((over ? Color(hex: 0xFF6B6B) : Color(hex: 0x2FD39B)).opacity(over ? 0.15 : 0.14), in: Capsule())
    }
}

/// The month pill with a chevron, as a menu.
struct MonthMenu: View {
    let months: [String]
    @Binding var selected: String

    var body: some View {
        Menu {
            ForEach(months, id: \.self) { m in
                Button(DateParse.monthLabel(m)) { selected = m }
            }
        } label: {
            HStack(spacing: 4) {
                Text(DateParse.monthLabel(selected))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.vib100)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// A dot with a soft glow, used in lists and budget cards.
struct GlowDot: View {
    let color: Color
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).shadow(color: color, radius: 3)
    }
}

enum Money {
    /// Always US style ("$1,234.56"), whatever region the phone is set to: an Indonesian region
    /// would otherwise show "US$1.234,56".
    static let locale = Locale(identifier: "en_US")

    static func usd(_ value: Double, cents: Bool = true) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(cents ? 2 : 0)).locale(locale))
    }

    /// "$123,632.26" → "$***,***.**" when `hidden` (More → Privacy → Hide balances).
    static func masked(_ text: String, _ hidden: Bool) -> String {
        hidden ? String(text.map { $0.isNumber ? "*" : $0 }) : text
    }

    /// A typed amount: "12.50", or "12,50" from a decimal pad set to a comma region.
    static func parse(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// "$4,300" for whole dollars, "$27.83" otherwise.
    static func plain(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.005 ? whole(value) : usd(value)
    }

    static func whole(_ value: Double) -> String {
        usd(value, cents: false)
    }

    static func format(_ value: Double, currency: String) -> String {
        if currency == "IDR" {
            return "Rp " + value.formatted(.number.precision(.fractionLength(0)).locale(Money.locale))
        }
        return value.formatted(.currency(code: currency).locale(locale))
    }

    /// "Rp 32.5M"
    static func shortIDR(_ value: Double) -> String {
        "Rp " + (value / 1_000_000).formatted(.number.precision(.fractionLength(1)).locale(Money.locale)) + "M"
    }
}

// MARK: - AI text

/// The agents write light markdown (**bold**, *italic*, "- " lists, the odd "## heading").
/// Show it as formatting instead of raw symbols.
enum AIMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let source = text.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                let heading = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? "" : "**\(heading)**"
            }
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { return "•  " + t.dropFirst(2) }
            return line
        }.joined(separator: "\n")
        if let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
           !String(parsed.characters).contains("**") {
            return parsed
        }
        return AttributedString(plain(text))  // unbalanced markers: drop them rather than show them
    }

    /// For places that can't show formatting (system notifications).
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "\\$", with: "$")
    }
}

// MARK: - Chart scrubbing

extension View {
    /// Touch the chart and drag: `date` follows the finger, snapped to the nearest of `points`
    /// (a pointer hover does the same on iPad and Mac); letting go clears it. The drag has priority
    /// over the page's scroll, so a finger on the chart always scrubs. Its position lives in a
    /// `@GestureState`, which resets even when the system cancels the touch, so the chart can't
    /// get stuck on a date. `date` only changes when the nearest point does, so the page isn't
    /// redrawn on every pixel of movement.
    func chartScrubbing(_ date: Binding<Date?>, points: [BalancePoint]) -> some View {
        modifier(ChartScrubbing(date: date, points: points))
    }
}

private struct ChartScrubbing: ViewModifier {
    @Binding var date: Date?
    let points: [BalancePoint]
    @GestureState private var finger: Date?
    @State private var hover: Date?

    func body(content: Content) -> some View {
        content
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let pick: (CGPoint) -> Date? = { point in
                        guard let frame = proxy.plotFrame else { return nil }
                        let x = min(max(point.x - geo[frame].minX, 0), geo[frame].width)
                        return proxy.value(atX: x, as: Date.self)
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .updating($finger) { value, state, _ in state = pick(value.location) }
                        )
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hover = pick(point)
                            case .ended: hover = nil
                            }
                        }
                }
            }
            .onChange(of: finger ?? hover) { _, new in
                let snapped = points.nearest(to: new)?.day
                if snapped != date { date = snapped }
            }
    }
}
