import Charts
import SwiftUI

/// Invest, built from mockups/portfolio-dark.html (Overview) and portfolio-asset-dark.html (Asset).
/// Overview: portfolio value with the change for the chosen range, a chart you can scrub (the value
/// above follows your finger), then net asset value and cash, broken down. Asset: filter chips, the
/// asset & cash value, holdings grouped by asset class, then sectors and the Investor's brief.
struct InvestView: View {
    enum Tab: String, CaseIterable { case overview = "Overview", asset = "Asset" }

    enum Range: String, CaseIterable {
        case week = "1W", month = "1M", quarter = "3M", ytd = "YTD", year = "1Y", all = "All"
        var days: Int {
            switch self {
            case .week: 7
            case .month: 30
            case .quarter: 91
            case .ytd, .year: 366
            case .all: 800
            }
        }
        var phrase: String {
            switch self {
            case .week: "past week"
            case .month: "past month"
            case .quarter: "past 3 months"
            case .ytd: "year to date"
            case .year: "past year"
            case .all: "all time"
            }
        }
    }

    @State private var tab: Tab = .overview
    @State private var range: Range = .year
    @State private var assetFilter = "All"
    @State private var data: PortfolioResponse?
    @State private var history: BalanceHistory?
    @State private var scrubDate: Date?  // set while a finger is on the chart
    @State private var working = false
    @State private var steps: [AgentEvent] = []
    @State private var error: String?

    private let api = APIClient()
    private static let gain = Color(hex: 0x4BE3A6)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Portfolio").font(.system(size: 32, weight: .bold)).tracking(-0.5).foregroundStyle(Theme.text)
                    .padding(.top, 2)
                tabs.padding(.top, 10).padding(.bottom, 16)
                if let data {
                    switch tab {
                    case .overview: overview(data)
                    case .asset: asset(data)
                    }
                } else if let error {
                    BackendErrorCard(message: error)
                } else {
                    ProgressView().tint(Theme.vib400).frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 180)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load(); await loadHistory() }
        .task { await load() }
        .task(id: range) { await loadHistory() }
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { tab = t } label: {
                    Text(t.rawValue).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tab == t ? .white : Theme.muted)
                        .padding(.top, 6).padding(.bottom, 9)
                        .overlay(alignment: .bottom) {
                            if tab == t { Rectangle().fill(Theme.vib400).frame(height: 2) }
                        }
                }
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    // MARK: Overview

    @ViewBuilder private func overview(_ d: PortfolioResponse) -> some View {
        let points = rangePoints
        let selected = scrubPoint
        Text("Portfolio value").font(.system(size: 15)).foregroundStyle(Theme.muted)
        SplitAmount(value: selected?.total ?? points.last?.total ?? d.snapshot.totalValue, size: 38)
            .padding(.top, 2)
            .contentTransition(.numericText())
        if let first = points.first, let end = selected ?? points.last, first.total > 0 {
            let diff = end.total - first.total
            (Text("\(diff < 0 ? "−" : "+")\(Money.usd(abs(diff))) (\((100 * abs(diff) / first.total).formatted(.number.precision(.fractionLength(1))))%) ")
                .foregroundColor(diff < 0 ? Theme.over : Self.gain)
             + Text(selected.map { "on \(DateParse.mediumDay($0.date))" } ?? range.phrase).foregroundColor(Theme.muted).fontWeight(.medium))
                .font(.system(size: 13.5, weight: .semibold)).monospacedDigit()
                .padding(.top, 6)
        }
        chart(points).padding(.top, 10)
        rangeButtons.padding(.top, 12)
        if let o = d.overview {
            navCard(o)
            cashCard(o)
        }
        sourceNote(d.source)
    }

    /// The chosen range's points (YTD is cut at Jan 1 of the latest year).
    private var rangePoints: [BalancePoint] {
        let points = history?.points ?? []
        guard range == .ytd, let last = points.last else { return points }
        return points.filter { $0.date >= "\(last.date.prefix(4))-01-01" }
    }

    private var scrubPoint: BalancePoint? {
        let points = rangePoints
        guard let scrubDate, !points.isEmpty else { return nil }
        return points.min { abs($0.day.timeIntervalSince(scrubDate)) < abs($1.day.timeIntervalSince(scrubDate)) }
    }

    @ViewBuilder private func chart(_ points: [BalancePoint]) -> some View {
        if points.count > 1 {
            let lo = points.map(\.total).min() ?? 0
            let hi = points.map(\.total).max() ?? 1
            let pad = max((hi - lo) * 0.08, 50)
            let ticks = [lo, (lo + hi) / 2, hi]
            VStack(spacing: 6) {
                Chart(points) { p in
                    AreaMark(x: .value("Day", p.day), yStart: .value("Low", lo - pad), yEnd: .value("Value", p.total))
                        .foregroundStyle(LinearGradient(colors: [Theme.vib400.opacity(0.35), Theme.vib400.opacity(0)],
                                                        startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", p.day), y: .value("Value", p.total))
                        .foregroundStyle(Color(hex: 0xB98CFF))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    if let s = scrubPoint, s.id == p.id {
                        RuleMark(x: .value("Day", p.day))
                            .foregroundStyle(Color(hex: 0xE3D2FF))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                Text(DateParse.mediumDay(p.date))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Theme.vib100)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Theme.vib900, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.vib300.opacity(0.5), lineWidth: 1))
                            }
                    }
                    if p.id == (scrubPoint ?? points.last)?.id {
                        PointMark(x: .value("Day", p.day), y: .value("Value", p.total))
                            .symbol {
                                Circle().fill(.white).frame(width: 9, height: 9)
                                    .overlay(Circle().stroke(Theme.vib400, lineWidth: 2.5))
                            }
                    }
                }
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: ticks) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Self.axisLabel(v)).font(.system(size: 11)).foregroundStyle(Color(hex: 0x8C839D)) }
                        }
                    }
                }
                .chartXSelection(value: $scrubDate)  // press and drag; letting go clears it
                .sensoryFeedback(.selection, trigger: scrubPoint?.date)
                .padding(.top, 24)  // room for the date pill
                .frame(height: 210)
                HStack {
                    Text(DateParse.mediumDay(points.first?.date ?? ""))
                    Spacer()
                    Text(DateParse.mediumDay(points.last?.date ?? "")).padding(.trailing, 50)
                }
                .font(.system(size: 11)).foregroundStyle(Color(hex: 0x8C839D)).monospacedDigit()
            }
        } else {
            Color.clear.frame(height: 236)
        }
    }

    /// "$60k", "$54.4k" (or the whole amount under $10k), as on the render's right edge.
    private static func axisLabel(_ v: Double) -> String {
        guard v >= 10_000 else { return Money.whole(v) }
        let k = (v / 100).rounded() / 10
        return "$" + (k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)) + "k"
    }

    private var rangeButtons: some View {
        HStack(spacing: 0) {
            ForEach(Range.allCases, id: \.self) { r in
                Button { range = r } label: {
                    Text(r.rawValue).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(range == r ? .white : Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background {
                            if range == r {
                                Capsule().fill(LinearGradient(colors: [Theme.vib500, Theme.vib700],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .shadow(color: Theme.vib500.opacity(0.45), radius: 7)
                            }
                        }
                }
            }
        }
        .padding(4)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }

    private func navCard(_ o: PortfolioOverview) -> some View {
        BreakdownCard(title: "Net asset value", value: o.netAssetValue,
                      info: "What your holdings are worth now, not counting cash. Realized P&L is estimated with your average cost.") {
            BreakdownRow(label: "Invested", value: Money.usd(o.invested))
            BreakdownRow(label: "Unrealized P&L", value: signed(o.unrealized), color: tone(o.unrealized))
            ForEach(o.unrealizedByClass) { c in
                BreakdownRow(label: c.name, value: signed(c.value), color: tone(c.value), sub: true)
            }
            BreakdownRow(label: "Realized P&L (YTD)", value: signed(o.realizedYtd), color: tone(o.realizedYtd))
            BreakdownRow(label: "Dividends (YTD)", value: Money.usd(o.dividendsYtd),
                         color: o.dividendsYtd == 0 ? Color(hex: 0x6F6683) : .white)
        }
        .padding(.top, 16)
    }

    private func cashCard(_ o: PortfolioOverview) -> some View {
        BreakdownCard(title: "Cash", value: o.cash, info: "Cash in each brokerage account, not invested yet.") {
            ForEach(o.cashAccounts) { a in
                BreakdownRow(label: "\(a.name) cash", value: Money.usd(a.cash),
                             color: a.cash == 0 ? Color(hex: 0x6F6683) : .white)
                if let idle = a.uninvested30Days {
                    BreakdownRow(label: "Uninvested for 30 days", value: Money.usd(idle), sub: true)
                }
            }
        }
        .padding(.top, 16)
    }

    private func signed(_ v: Double) -> String { "\(v < 0 ? "−" : "+")\(Money.usd(abs(v)))" }
    private func tone(_ v: Double) -> Color { v < 0 ? Theme.over : v > 0 ? Self.gain : Color(hex: 0x6F6683) }

    @ViewBuilder private func sourceNote(_ source: String?) -> some View {
        let live = source == "snaptrade_sandbox"
        let cutoff = history?.syntheticBefore.map { " History before \(DateParse.mediumDay($0)) is generated." } ?? ""
        Text((live ? "Live from the SnapTrade sandbox." : "Sample data.") + cutoff)
            .font(.system(size: 10.5)).foregroundStyle(Theme.muted).padding(.top, 12)
    }

    // MARK: Asset

    /// Built from mockups/portfolio-asset-dark.html: filter chips, the asset & cash value card, then
    /// holdings grouped by asset class. Sectors and the Investor's brief follow (not in the render;
    /// they carry the sector limit and the AI brief).
    @ViewBuilder private func asset(_ d: PortfolioResponse) -> some View {
        let groups = assetGroups(d.snapshot.holdings)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(["All"] + groups.map(\.name), id: \.self) { name in
                        Button { assetFilter = name } label: {
                            Text(Self.display(name)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(assetFilter == name ? .white : Theme.muted)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(assetFilter == name ? Theme.vib500.opacity(0.22) : .white.opacity(0.05), in: Capsule())
                                .overlay(Capsule().stroke(assetFilter == name ? Theme.vib300.opacity(0.6) : .white.opacity(0.08), lineWidth: 1))
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 14)
            if let o = d.overview { assetCashCard(o) }
            ForEach(groups.filter { assetFilter == "All" || $0.name == assetFilter }, id: \.name) { g in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(Self.display(g.name)) · \(Money.usd(g.holdings.reduce(0) { $0 + $1.value }))")
                            .font(.system(size: 15, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                        Spacer()
                        Text("Value / P&L").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 2).padding(.bottom, 4)
                    ForEach(g.holdings) { HoldingRow(holding: $0) }
                }
                .padding(.top, 20)
            }
            VStack(alignment: .leading, spacing: 16) {
                sectors(d.snapshot)
                briefCard
            }
            .padding(.top, 24)
        }
    }

    private func assetGroups(_ holdings: [Holding]) -> [(name: String, holdings: [Holding])] {
        let order = ["US stocks", "Funds", "Crypto"]
        let grouped = Dictionary(grouping: holdings) { $0.assetClass ?? "US stocks" }
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1) }
            .map { (name: $0, holdings: grouped[$0]!.sorted { $0.value > $1.value }) }
    }

    private static func display(_ name: String) -> String { name == "US stocks" ? "US Stocks" : name }

    private func assetCashCard(_ o: PortfolioOverview) -> some View {
        AssetCashCard(overview: o, total: o.netAssetValue + o.cash)
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

    // MARK: Loading

    private func load() async {
        do {
            data = try await api.get("portfolio")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadHistory() async {
        history = try? await api.get("portfolio/history", query: ["days": "\(range.days)"])
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

/// A "Net asset value" / "Cash" card from the render: title with an info button, the total with a
/// chevron that folds the breakdown, and the rows on a slightly lighter panel.
struct BreakdownCard<Rows: View>: View {
    let title: String
    let value: Double
    let info: String
    @ViewBuilder var rows: Rows

    @State private var open = true
    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showInfo.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14)).foregroundStyle(Color(hex: 0xD8CDEB))
                        Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Button { withAnimation(.snappy) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.muted)
                        Text(Money.usd(value)).font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                    }
                }
            }
            .padding(.horizontal, 2)
            if showInfo {
                Text(info).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 6).padding(.horizontal, 2)
            }
            if open {
                VStack(spacing: 0) { rows }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct BreakdownRow: View {
    let label: String
    let value: String
    var color: Color = .white
    var sub = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(sub ? Theme.muted : Color(hex: 0xCFC5E2))
            Spacer()
            Text(value).fontWeight(sub ? .medium : .semibold).foregroundStyle(color).monospacedDigit()
        }
        .font(.system(size: sub ? 12.5 : 13.5))
        .padding(.leading, sub ? 14 : 0)
        .padding(.vertical, 6)
    }
}

/// "Asset & cash value": the total with a chevron that folds the rows, the net asset value and each
/// account's cash, and the unrealized P&L at the foot (its chevron opens the split by asset class).
struct AssetCashCard: View {
    let overview: PortfolioOverview
    let total: Double

    @State private var open = true
    @State private var split = false
    private static let gain = Color(hex: 0x4BE3A6)

    var body: some View {
        let o = overview
        let pct = o.invested > 0 ? 100 * o.unrealized / o.invested : 0
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text("Asset & cash value").font(.system(size: 14)).foregroundStyle(Color(hex: 0xD8CDEB))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                    Text(Money.usd(total)).font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 2)
            if open {
                VStack(spacing: 0) {
                    BreakdownRow(label: "Net asset value", value: Money.usd(o.netAssetValue))
                    ForEach(o.cashAccounts) { a in
                        BreakdownRow(label: "\(a.name) cash", value: Money.usd(a.cash),
                                     color: a.cash == 0 ? Color(hex: 0x6F6683) : .white)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 10)
            }
            Button { withAnimation(.snappy) { split.toggle() } } label: {
                HStack {
                    Text("Unrealized P&L").font(.system(size: 14)).foregroundStyle(Color(hex: 0xD8CDEB))
                    Spacer()
                    Image(systemName: split ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.muted)
                    Text("\(o.unrealized < 0 ? "−" : "+")\(Money.usd(abs(o.unrealized))) (\(abs(pct).formatted(.number.precision(.fractionLength(2))))%)")
                        .font(.system(size: 14, weight: .bold)).monospacedDigit()
                        .foregroundStyle(o.unrealized < 0 ? Theme.over : Self.gain)
                }
            }
            .padding(.top, 10).padding(.horizontal, 2)
            if split {
                VStack(spacing: 0) {
                    ForEach(o.unrealizedByClass) { c in
                        BreakdownRow(label: c.name == "US stocks" ? "US Stocks" : c.name,
                                     value: "\(c.value < 0 ? "−" : "+")\(Money.usd(abs(c.value)))",
                                     color: c.value < 0 ? Theme.over : Self.gain, sub: true)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// One holding: a round badge in the company's colors, the ticker with a short name and the amount
/// held, then the value and the unrealized P&L.
struct HoldingRow: View {
    let holding: Holding
    private static let gain = Color(hex: 0x4BE3A6)

    var body: some View {
        let h = holding
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: Self.colors(h.symbol), startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(Self.mark(h.symbol)).font(.system(size: Self.symbols[h.symbol] == nil ? 12 : 18, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Text("\(Self.shortName(h)) · \(Self.amount(h))").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.usd(h.value)).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                if let g = h.gain {
                    let cost = h.value - g
                    let pct = cost > 0 ? 100 * g / cost : 0
                    Text("\(g < 0 ? "−" : "+")\(Money.usd(abs(g))) (\(abs(pct).formatted(.number.precision(.fractionLength(2))))%)")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(g < 0 ? Theme.over : g > 0 ? Self.gain : Theme.muted)
                }
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private static let symbols = ["BTC": "₿", "ETH": "Ξ", "SOL": "◎", "USDC": "$"]

    private static func mark(_ symbol: String) -> String { symbols[symbol] ?? String(symbol.prefix(2)) }

    /// Brand-like colors for well-known tickers; the app's purple for anything else.
    private static func colors(_ symbol: String) -> [Color] {
        let pairs: [String: (UInt32, UInt32)] = [
            "NVDA": (0x76B900, 0x3D6100), "AAPL": (0x8E8E93, 0x3A3A3C), "MSFT": (0x2F8CFF, 0x0B3F8C),
            "GOOGL": (0x4285F4, 0x1A4FA8), "GOOG": (0x4285F4, 0x1A4FA8), "TSLA": (0xE31937, 0x7A0A1A),
            "COST": (0xE31837, 0x005DAA), "VOO": (0xC0392B, 0x6E1A12), "SPY": (0x2F8CFF, 0x0B2E6E),
            "FXAIX": (0x4AA564, 0x1E5A31), "GLD": (0xF5C542, 0xB8860B), "BTC": (0xF7931A, 0xA85C00),
            "ETH": (0x8C8CF7, 0x3C3CA8), "SOL": (0x9945FF, 0x14A08A), "USDC": (0x2775CA, 0x12407A),
        ]
        let (a, b) = pairs[symbol] ?? (0xA45CFF, 0x4B1A8C)
        return [Color(hex: a), Color(hex: b)]
    }

    /// "Alphabet Inc. Class A Common Stock" → "Alphabet"
    private static func shortName(_ h: Holding) -> String {
        var n = h.name ?? h.symbol
        for cut in [" Class A", " Class B", " Common Stock", ", Inc.", " Inc.", " Corporation", " Corp."] {
            if let r = n.range(of: cut) { n = String(n[..<r.lowerBound]) }
        }
        return n.isEmpty ? h.symbol : n
    }

    private static func amount(_ h: Holding) -> String {
        let q = h.quantity.formatted(.number.precision(.fractionLength(0...4)))
        return h.assetClass == "Crypto" ? "\(q) \(h.symbol)" : "\(q) \(h.quantity == 1 ? "share" : "shares")"
    }
}
