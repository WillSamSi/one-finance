import Charts
import SwiftUI

/// Wallet: total assets over time (area chart), accounts, the Review tray and pocket links.
struct WalletView: View {
    enum Range: String, CaseIterable {
        case week = "1W", month = "1M", quarter = "3M", half = "6M", year = "1Y", twoYears = "2Y"
        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 91
            case .half: 182
            case .year: 365
            case .twoYears: 730
            }
        }
    }

    @State private var range: Range = .month
    @State private var history: BalanceHistory?
    @State private var accounts: AccountsResponse?
    @State private var review: [ReviewItem] = []
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Wallet", subtitle: "Every account, in one place")
                chartCard
                reviewCard
                accountsCard
                if let error { BackendErrorCard(message: error) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 180)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .task { await load() }
        .task(id: range) { await loadHistory() }
    }

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Total assets").font(.system(size: 13)).foregroundStyle(Theme.muted)
                if let last = history?.points.last, let first = history?.points.first {
                    Text(Money.usd(last.total)).font(.system(size: 28, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                    let change = last.total - first.total
                    Chip(text: "\(change >= 0 ? "▲" : "▼") \(Money.usd(abs(change))) · \(range.rawValue)")
                }
                if let points = history?.points, !points.isEmpty {
                    let lo = points.map(\.total).min() ?? 0
                    let hi = points.map(\.total).max() ?? 1
                    Chart(points) { p in
                        AreaMark(x: .value("Day", p.day), yStart: .value("Low", lo - (hi - lo) * 0.1), yEnd: .value("Total", p.total))
                            .foregroundStyle(LinearGradient(colors: [Theme.vib500.opacity(0.45), Theme.vib500.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", p.day), y: .value("Total", p.total))
                            .foregroundStyle(Theme.vib400)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: (lo - (hi - lo) * 0.1)...(hi + (hi - lo) * 0.05 + 1))
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel().foregroundStyle(Theme.muted) } }
                    .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel().foregroundStyle(Theme.muted)
                    } }
                    .frame(height: 180)
                }
                HStack(spacing: 6) {
                    ForEach(Range.allCases, id: \.self) { r in
                        Button { range = r } label: {
                            Text(r.rawValue).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(range == r ? Theme.vib100 : Theme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 6)
                                .background(range == r ? Theme.vib500.opacity(0.25) : .clear, in: Capsule())
                        }
                    }
                }
                if let cutoff = history?.syntheticBefore {
                    Text("Sample data. History before \(DateParse.shortDay(cutoff)), \(cutoff.prefix(4)) is generated.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var reviewCard: some View {
        AICard {
            VStack(alignment: .leading, spacing: 10) {
                AILabel(title: "Review", note: review.isEmpty ? "all clear" : "\(review.count) to check")
                if review.isEmpty {
                    Text("Nothing flagged. Run the month-end check in Other to have the Accountant look.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                ForEach(review) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            if let m = item.month { Text(DateParse.monthLabel(m)).font(.caption).foregroundStyle(Theme.muted) }
                        }
                        Text(item.detail).font(.system(size: 12.5)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button { Task { await resolve(item, "confirmed") } } label: { Chip(text: "Confirm") }
                            Button { Task { await resolve(item, "dismissed") } } label: { Chip(text: "Dismiss", color: Theme.muted) }
                        }
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: -4) }
                }
            }
        }
    }

    private var accountsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Accounts").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                ForEach(accounts?.accounts ?? []) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name).foregroundStyle(Theme.text)
                            Text("\(account.institution) ····\(account.mask ?? "")").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.format(account.type == "credit" ? -account.currentBalance : account.currentBalance, currency: account.currency))
                                .foregroundStyle(account.type == "credit" ? Theme.negative : Theme.text)
                                .monospacedDigit()
                            if account.currency != "USD" {
                                Text(Money.usd(account.balanceUsd)).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        do {
            accounts = try await api.get("accounts")
            review = (try await api.get("review") as ReviewList).items
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await loadHistory()
    }

    private func loadHistory() async {
        history = try? await api.get("balance-history", query: ["days": "\(range.days)"])
    }

    private func resolve(_ item: ReviewItem, _ status: String) async {
        let _: OK? = try? await api.post("review/\(item.id)/resolve", body: ["status": status])
        review.removeAll { $0.id == item.id }
    }
}
