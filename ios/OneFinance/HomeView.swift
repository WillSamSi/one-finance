import SwiftUI

/// Home: total assets and every account, loaded from the backend.
/// The area chart, Sankey and pockets come in Phase 3.
struct HomeView: View {
    @State private var accounts: AccountsResponse?
    @State private var health: Health?
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let accounts {
                        totalCard(accounts.totalAssetsUsd)
                        accountsCard(accounts.accounts)
                    } else if let error {
                        errorCard(error)
                    } else {
                        ProgressView().tint(Theme.vib400).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(20)
            }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("One Finance")
                .font(.largeTitle.bold())
                .foregroundStyle(
                    LinearGradient(colors: [Theme.vib100, Theme.vib400], startPoint: .leading, endPoint: .trailing)
                )
            if let health {
                Text("As of \(health.appDate) · \(health.dataMode == "sample" ? "Sample data" : "Live data")")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func totalCard(_ total: Double) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Total assets").font(.subheadline).foregroundStyle(Theme.muted)
                Text(Money.usd(total))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .monospacedDigit()
                Text("Banks, cards, investments and Indonesian accounts, in USD")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func accountsCard(_ accounts: [Account]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accounts").font(.headline).foregroundStyle(Theme.text)
                ForEach(accounts) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).foregroundStyle(Theme.text)
                            Text("\(account.institution) ····\(account.mask ?? "")")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.format(account.type == "credit" ? -account.currentBalance : account.currentBalance,
                                              currency: account.currency))
                                .foregroundStyle(account.type == "credit" ? Theme.negative : Theme.text)
                                .monospacedDigit()
                            if account.currency != "USD" {
                                Text(Money.usd(account.balanceUsd)).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if account.id != accounts.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Can't reach the backend").font(.headline).foregroundStyle(Theme.text)
                Text("Start it with: .venv/bin/uvicorn backend.main:app --port 8000")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.muted)
                Text(message).font(.caption2).foregroundStyle(Theme.muted)
            }
        }
    }

    private func load() async {
        do {
            async let h: Health = api.get("health")
            async let a: AccountsResponse = api.get("accounts")
            (health, accounts) = try await (h, a)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    HomeView().preferredColorScheme(.dark)
}
