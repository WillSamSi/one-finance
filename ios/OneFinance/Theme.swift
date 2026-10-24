import SwiftUI

/// Colors from the dark "vibranium" mockup (mockups/home-dark.html).
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

    static let background = LinearGradient(
        colors: [onyx900, onyx950],
        startPoint: .top,
        endPoint: .bottom
    )
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

/// A rounded card with the mockup's hairline border.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.onyx800, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

enum Money {
    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }

    static func format(_ value: Double, currency: String) -> String {
        if currency == "IDR" {
            return "Rp " + value.formatted(.number.precision(.fractionLength(0)))
        }
        return value.formatted(.currency(code: currency))
    }
}
