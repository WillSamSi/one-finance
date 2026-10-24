import SwiftUI

/// Invest: positions, sector shares vs the owner's limit, and the Investor's latest brief.
struct InvestView: View {
    @State private var data: PortfolioResponse?
    @State private var working = false
    @State private var steps: [AgentEvent] = []
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "Invest", subtitle: data?.snapshot.account)
                if let p = data?.snapshot {
                    summary(p)
                    sectors(p)
                    holdings(p)
                }
                briefCard
                if let error { BackendErrorCard(message: error) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 180)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .task { await load() }
    }

    private func summary(_ p: Portfolio) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Portfolio value").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Text(Money.usd(p.totalValue)).font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                Text("Cash \(Money.usd(p.cash)) (\(p.cashPct.formatted(.number.precision(.fractionLength(1))))%)")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func sectors(_ p: Portfolio) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sectors").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Your limit: \(Int(p.maxSectorSharePct))% per sector").font(.caption).foregroundStyle(Theme.muted)
                ForEach(p.sectorSharesPct.sorted { $0.value > $1.value }, id: \.key) { name, share in
                    let over = share > p.maxSectorSharePct && !name.hasPrefix("Fund")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name).font(.system(size: 13)).foregroundStyle(Theme.text)
                            Spacer()
                            if over { Tag(text: "Over limit", over: true) }
                            Text("\(share.formatted(.number.precision(.fractionLength(1))))%")
                                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(over ? Theme.over : Theme.text)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill(over ? Color(hex: 0xFF6B6B) : Theme.vib400).frame(width: geo.size.width * share / 100)
                                Rectangle().fill(.white.opacity(0.7)).frame(width: 2, height: 10)
                                    .offset(x: geo.size.width * p.maxSectorSharePct / 100 - 1)
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    private func holdings(_ p: Portfolio) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Holdings").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                ForEach(p.holdings) { h in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("\(h.sector) · \(h.weightPct.formatted(.number.precision(.fractionLength(1))))%")
                                .font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.usd(h.value)).monospacedDigit().foregroundStyle(Theme.text)
                            if let g = h.gainPct {
                                Text("\(g >= 0 ? "+" : "")\(g.formatted(.number.precision(.fractionLength(1))))%")
                                    .font(.caption).monospacedDigit().foregroundStyle(g >= 0 ? Theme.positive : Theme.over)
                            }
                        }
                    }
                }
            }
        }
    }

    private var briefCard: some View {
        AICard {
            VStack(alignment: .leading, spacing: 10) {
                AILabel(title: "Investor's brief", note: data?.latestBrief.map { "as of \($0.asOf)" })
                if let b = data?.latestBrief {
                    ForEach(b.concentration + b.risks, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            GlowDot(color: Color(hex: 0xFF8A4C))
                            Text(line).font(.system(size: 13)).foregroundStyle(Theme.cardText)
                        }
                    }
                    ForEach(b.holdings) { h in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text(h.keyNumbers).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    Text("From SEC filings. Suggestions only; the app can't trade.").font(.caption2).foregroundStyle(Theme.muted)
                } else {
                    Text("Ask the Investor to read your positions and the companies' SEC filings.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                if working { AgentActivity(steps: steps) }
                Button { Task { await runBrief() } } label: {
                    Chip(text: working ? "Investor is working…" : "Ask the Investor for a brief")
                }
                .disabled(working)
            }
        }
    }

    private func load() async {
        do {
            data = try await api.get("portfolio")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runBrief() async {
        working = true
        steps = []
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            let _: AgentRunResult = try await api.post("agents/portfolio-brief")
        } catch {
            self.error = error.localizedDescription
        }
        watcher.cancel()
        working = false
        await load()
    }
}
