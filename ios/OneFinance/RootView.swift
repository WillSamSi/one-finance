import SwiftUI

enum AppTab: String, CaseIterable {
    case home, wallet, invest, search, other

    var icon: String {
        switch self {
        case .home: return "house"
        case .wallet: return "wallet.bifold"
        case .invest: return "chart.bar.xaxis.ascending"
        case .search: return "magnifyingglass"
        case .other: return "line.3.horizontal"
        }
    }
}

/// The app shell from the render: content, a floating dock (rounded tab bar + AI ring button)
/// and, on Home, the floating + button for manual expenses.
struct RootView: View {
    @State private var tab: AppTab = .home
    @State private var showChat = false
    @State private var showAdd = false
    @State private var reloadToken = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background
            Group {
                switch tab {
                case .home: HomeView(reloadToken: reloadToken, openTab: { tab = $0 })
                case .wallet: WalletView()
                case .invest: InvestView()
                case .search: SearchView()
                case .other: OtherView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                // Content scrolling under the dock fades out, all the way to the screen's edge.
                LinearGradient(stops: [.init(color: Theme.onyx950, location: 0),
                                       .init(color: Theme.onyx950.opacity(0.96), location: 0.5),
                                       .init(color: .clear, location: 1)],
                               startPoint: .bottom, endPoint: .top)
                    .frame(height: 170)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }

            if tab == .home {
                HStack {
                    Spacer()
                    AddButton { showAdd = true }
                        .padding(.trailing, 25)
                        .padding(.bottom, 92)
                }
            }

            Dock(tab: $tab, onAI: { showChat = true })
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
        }
        .sheet(isPresented: $showChat) { ChatSheet() }
        .sheet(isPresented: $showAdd) { AddExpenseSheet { reloadToken += 1 } }
        .task { await LocalNotifications.requestPermission() }
    }
}

struct Dock: View {
    @Binding var tab: AppTab
    let onAI: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack {
                ForEach(AppTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tab == t ? Theme.vib300 : Color(hex: 0x8C839D))
                            .frame(width: 52, height: 48)
                            .background(tab == t ? Theme.vib500.opacity(0.20) : .clear, in: RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).stroke(tab == t ? Theme.vib400.opacity(0.30) : .clear, lineWidth: 1))
                    }
                    .accessibilityLabel(t.rawValue.capitalized)
                    if t != AppTab.allCases.last { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 64)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .background(Color(red: 24 / 255, green: 20 / 255, blue: 32 / 255).opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(Theme.vib300.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 15, y: 12)

            Button(action: onAI) {
                AIRing()
                    .frame(width: 64, height: 64)
                    .background(
                        RadialGradient(colors: [Color(hex: 0x1D1729), Color(hex: 0x0C0A11)], center: UnitPoint(x: 0.5, y: 0.35),
                                       startRadius: 0, endRadius: 32),
                        in: Circle())
                    .overlay(Circle().stroke(Theme.vib300.opacity(0.20), lineWidth: 1))
                    .shadow(color: Color(red: 110 / 255, green: 90 / 255, blue: 1).opacity(0.28), radius: 13)
            }
            .accessibilityLabel("Ask the AI")
        }
    }
}

struct AddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    RadialGradient(colors: [Theme.vib400, Theme.vib500, Theme.vib700], center: UnitPoint(x: 0.35, y: 0.3),
                                   startRadius: 0, endRadius: 30),
                    in: Circle())
                .overlay(Circle().stroke(Color(hex: 0xD6BAFF, opacity: 0.45), lineWidth: 1))
                .shadow(color: Theme.vib500.opacity(0.55), radius: 11)
        }
        .accessibilityLabel("Add expense")
    }
}

/// Title row used at the top of every tab except Home.
struct ScreenTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
