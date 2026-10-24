import SwiftUI

/// The five tabs from the mockup. The AI agent button arrives in Phase 3.
struct RootView: View {
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.onyx900)
        UITabBarItem.appearance().setTitleTextAttributes([.foregroundColor: UIColor(Theme.muted)], for: .normal)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = UIColor(Theme.muted)
    }

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            PlaceholderView(title: "Wallet", note: "Accounts, pockets and the Review tray")
                .tabItem { Label("Wallet", systemImage: "wallet.bifold.fill") }
            PlaceholderView(title: "Invest", note: "Positions and the Investor's briefs")
                .tabItem { Label("Invest", systemImage: "chart.line.uptrend.xyaxis") }
            PlaceholderView(title: "Search", note: "Find any transaction, receipt or order")
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            PlaceholderView(title: "Other", note: "Notifications, receipts, settings")
                .tabItem { Label("Other", systemImage: "ellipsis.circle.fill") }
        }
        .tint(Theme.vib400)
    }
}

struct PlaceholderView: View {
    let title: String
    let note: String

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 8) {
                Text(title).font(.title2.bold()).foregroundStyle(Theme.text)
                Text(note).font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }
}

#Preview {
    RootView().preferredColorScheme(.dark)
}
