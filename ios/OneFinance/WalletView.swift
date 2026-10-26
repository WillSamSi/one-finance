import Charts
import SwiftUI

/// Wallet, built from mockups/wallet-dark.html: Balance (by institution: US banks, then
/// Indonesian banks, then investments), Debt Balance, Pockets in full, the Cash check,
/// Budget setup, and the Review tray.
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
        var phrase: String {
            switch self {
            case .week: "past week"
            case .month: "past month"
            case .quarter: "past 3 months"
            case .half: "past 6 months"
            case .year: "past year"
            case .twoYears: "past 2 years"
            }
        }
    }

    @State private var range: Range = .quarter
    @State private var history: BalanceHistory?
    @State private var data: WalletData?
    @State private var review: [ReviewItem] = []
    @State private var error: String?
    @State private var showSetup = false
    @State private var scrubDate: Date?  // set while a finger is on the chart
    @State private var suggestOnOpen = false

    private let api = APIClient()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Wallet").font(.system(size: 30, weight: .bold)).tracking(-0.5).foregroundStyle(Theme.text)
                if let d = data {
                    balanceCard(d)
                    debtCard(d.debts)
                    pocketsCard(d)
                    cashCheckCard(d.cashCheck)
                    setupCard
                    reviewCard
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
        .scrollDisabled(scrubDate != nil)  // a finger on the chart scrubs; the page stays put
        .refreshable { await load() }
        .task { await load() }
        .task(id: range) { await loadHistory() }
        .sheet(isPresented: $showSetup, onDismiss: { Task { await load() } }) {
            BudgetSetupSheet(suggestOnOpen: suggestOnOpen)
        }
    }

    // MARK: Balance

    private func balanceCard(_ d: WalletData) -> some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 0) {
                let selected = scrubPoint
                Text(selected.map { "Balance on \(DateParse.shortDay($0.date)), \($0.date.prefix(4))" } ?? "Balance")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                SplitAmount(value: selected?.total ?? d.balance.total, size: 32).padding(.top, 2)
                    .contentTransition(.numericText())
                HStack(spacing: 8) {
                    if let first = history?.points.first, let end = selected ?? history?.points.last, first.total > 0 {
                        let change = end.total - first.total
                        Chip(text: "\(change >= 0 ? "▲" : "▼") \(Money.whole(abs(change))) · \((100 * change / first.total).formatted(.number.precision(.fractionLength(1))))%")
                    }
                    Text(selected == nil ? "\(range.phrase) · \(d.balance.institutions) institutions"
                                         : "since \(DateParse.shortDay(history?.points.first?.date ?? ""))")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .padding(.top, 4)
                areaChart.padding(.top, 10)
                rangeButtons.padding(.top, 8)
                allocationBar(d.institutions).padding(.top, 12)
                ForEach(d.institutions) { InstitutionRow(group: $0).padding(.top, 10) }
                if let cutoff = history?.syntheticBefore {
                    Text("Sample data. History before \(DateParse.shortDay(cutoff)), \(cutoff.prefix(4)) is generated.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted).padding(.top, 10)
                }
            }
        }
    }

    @ViewBuilder private var areaChart: some View {
        if let points = history?.points, !points.isEmpty {
            let lo = points.map(\.total).min() ?? 0
            let hi = points.map(\.total).max() ?? 1
            let floor = lo - (hi - lo) * 0.15 - 1
            Chart(points) { p in
                AreaMark(x: .value("Day", p.day), yStart: .value("Low", floor), yEnd: .value("Total", p.total))
                    .foregroundStyle(LinearGradient(colors: [Theme.vib400.opacity(0.45), Theme.vib400.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Day", p.day), y: .value("Total", p.total))
                    .foregroundStyle(Color(hex: 0xB98CFF))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                if let s = scrubPoint, s.id == p.id {
                    RuleMark(x: .value("Day", p.day))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text("\(DateParse.shortDay(p.date)) · \(Money.whole(p.total))")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(Theme.vib100)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.onyx700, in: Capsule())
                                .overlay(Capsule().stroke(Theme.vib400.opacity(0.35), lineWidth: 1))
                        }
                    PointMark(x: .value("Day", p.day), y: .value("Total", p.total))
                        .symbolSize(70)
                        .foregroundStyle(.white)
                } else if scrubPoint == nil, p.id == points.last?.id {
                    PointMark(x: .value("Day", p.day), y: .value("Total", p.total))
                        .symbolSize(60)
                        .foregroundStyle(.white)
                }
            }
            .chartYScale(domain: floor...(hi + (hi - lo) * 0.05 + 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartScrubbing($scrubDate)  // touch and drag; letting go clears it
            .sensoryFeedback(.selection, trigger: scrubPoint?.date)
            .padding(.top, 22)  // room for the date label
            .frame(height: 142)
        } else {
            Color.clear.frame(height: 142)
        }
    }

    /// The day closest to the finger, while scrubbing.
    private var scrubPoint: BalancePoint? {
        guard let scrubDate, let points = history?.points, !points.isEmpty else { return nil }
        return points.min { abs($0.day.timeIntervalSince(scrubDate)) < abs($1.day.timeIntervalSince(scrubDate)) }
    }

    private var rangeButtons: some View {
        HStack {
            ForEach(Range.allCases, id: \.self) { r in
                Button { range = r } label: {
                    Text(r.rawValue).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(range == r ? Theme.vib100 : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(range == r ? Theme.vib500.opacity(0.22) : .clear, in: Capsule())
                        .overlay(Capsule().stroke(range == r ? Theme.vib400.opacity(0.35) : .clear, lineWidth: 1))
                }
                if r != Range.allCases.last { Spacer(minLength: 0) }
            }
        }
    }

    private func allocationBar(_ groups: [Institution]) -> some View {
        let total = max(1, groups.reduce(0) { $0 + $1.totalUsd })
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(groups) { g in
                        Capsule().fill(InstitutionLogo.color(g.institution))
                            .frame(width: max(4, (geo.size.width - CGFloat(groups.count - 1) * 3) * g.totalUsd / total))
                    }
                }
            }
            .frame(height: 6)
            FlowKey(items: groups.map { (InstitutionLogo.shortName($0.institution), InstitutionLogo.color($0.institution),
                                         100 * $0.totalUsd / total) })
        }
    }

    // MARK: Debts

    private func debtCard(_ debts: [Debt]) -> some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Debt Balance").font(.system(size: 14)).foregroundStyle(Theme.muted)
                SplitAmount(value: debts.reduce(0) { $0 + $1.owed }, size: 32).padding(.top, 2)
                let next = debts.compactMap(\.nextAutopay).sorted().first
                Text("\(Self.debtCounts(debts))\(next.map { " · next payment \(DateParse.shortDay($0))" } ?? "")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
                ForEach(debts) { DebtRow(debt: $0).padding(.top, 10) }
            }
        }
    }

    /// "2 cards · 1 mortgage · 1 installment plan"
    static func debtCounts(_ debts: [Debt]) -> String {
        let groups: [(String, String, String)] = [("card", "card", "cards"), ("mortgage", "mortgage", "mortgages"),
                                                  ("loan", "loan", "loans"), ("installment", "installment plan", "installment plans")]
        return groups.compactMap { kind, one, many in
            let n = debts.filter { ($0.kind ?? "card") == kind }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }.joined(separator: " · ")
    }

    // MARK: Pockets

    private func pocketsCard(_ d: WalletData) -> some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pockets").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        Text("Labels on your money, not tied to any account").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(DateParse.monthLabel(d.month))
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.vib100)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.white.opacity(0.05), in: Capsule())
                        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                groupHeader("Spending", "\(Money.whole(d.spending.totalLeft)) left of \(Money.whole(d.spending.totalBudget))")
                ForEach(d.spending.pockets) { p in
                    PocketRow(name: p.name, color: Theme.category(p.name),
                              value: (p.over ? "−" : "") + Money.whole(abs(p.left)), sub: nil,
                              suffix: "/ \(Money.whole(p.available))", over: p.over,
                              progress: p.available > 0 ? p.spent / p.available : 1)
                }
                let saving = d.savings.filter { $0.kind == "saving" }
                groupHeader("Savings", "\(Money.whole(saving.reduce(0) { $0 + $1.total })) saved")
                ForEach(saving) { s in
                    PocketRow(name: s.name, color: Theme.category(s.name), value: Money.whole(s.total),
                              sub: savingSub(s, month: d.month), suffix: nil, over: false,
                              progress: s.pctOfGoal.map { $0 / 100 })
                }
                ForEach(d.savings.filter { $0.kind == "investing" }) { s in
                    groupHeader("Investing", "\(monthShort(d.month)) +\(Money.whole(s.thisMonth)) of \(Money.whole(s.monthlyAmount ?? 0))\(s.thisMonth >= (s.monthlyAmount ?? 0) ? " ✓" : "")")
                    PocketRow(name: "Ready to invest", color: Theme.category("Investment"), value: Money.whole(s.total),
                              sub: "Set aside to move to the brokerage", suffix: nil, over: false, progress: nil)
                }
                groupHeader("Unassigned", "Not in any pocket yet")
                PocketRow(name: "Unassigned", color: Color(hex: 0x9AA6C2), value: Money.usd(d.cashCheck.unassigned),
                          sub: nil, suffix: nil, over: d.cashCheck.unassigned < 0, progress: nil)
                if !d.moves.filter({ $0.undone == 0 }).isEmpty {
                    groupHeader("Recent moves", "In the app only, no bank transfer")
                    ForEach(d.moves.filter { $0.undone == 0 }) { m in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Money.usd(m.amount)): \(m.fromPocket ?? "Unassigned") → \(m.toPocket ?? "Unassigned")")
                                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("\(m.createdBy == "advisor" ? "By the Advisor" : "By you") · \(DateParse.shortDay(m.date))\(m.note.map { " · \($0)" } ?? "")")
                                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                            Spacer()
                            Button { Task { await undo(m) } } label: { Chip(text: "Undo") }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func groupHeader(_ title: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(.system(size: 12, weight: .bold)).tracking(0.6).foregroundStyle(Theme.vib300)
            Spacer()
            Text(note).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Theme.muted)
        }
        .padding(.top, 16)
        .padding(.bottom, 2)
    }

    private func monthShort(_ month: String) -> String { String(DateParse.monthLabel(month).prefix(3)) }

    private func savingSub(_ s: SavingsPocket, month: String) -> String {
        var parts: [String] = []
        if let goal = s.goal {
            parts.append("Goal \(Money.whole(goal))\(s.goalDate.map { " by \(DateParse.monthLabel($0))" } ?? "")")
        } else {
            parts.append("No goal")
        }
        if s.thisMonth > 0 { parts.append("\(monthShort(month)) +\(Money.whole(s.thisMonth)) ✓") }
        return parts.joined(separator: " · ")
    }

    // MARK: Cash check

    private func cashCheckCard(_ c: CashCheck) -> some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cash check").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        Text("Pockets + Unassigned = all my money").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(c.balanced ? "✓ Balanced" : "! Over-assigned")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(c.balanced ? Color(hex: 0x7FE8C0) : Color(hex: 0xFF9A8A))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background((c.balanced ? Color(hex: 0x2FD39B) : Color(hex: 0xFF6B6B)).opacity(0.14), in: Capsule())
                }
                Spacer().frame(height: 12)
                checkRow("Cash in US banks", c.cashUs)
                checkRow("Cash in Indonesian banks", c.cashIndonesia)
                checkRow("Owed on credit cards", -c.owedOnCards)
                checkRow("All my money", c.allMoney, total: true)
                Spacer().frame(height: 12)
                checkRow("Spending pockets (left)", c.spendingLeft)
                checkRow("Savings + investing pockets", c.savingsAndInvesting)
                checkRow("Unassigned", c.unassigned)
                checkRow("Pockets + Unassigned", c.pocketsPlusUnassigned, total: true)
                Text(c.balanced ? "The brokerage is tracked on its own, not in pockets."
                                : "Your pockets promise more money than you have. Lower a budget or a savings amount.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 10)
            }
        }
    }

    private func checkRow(_ label: String, _ value: Double, total: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value < 0 ? "−" + Money.usd(-value) : Money.usd(value)).monospacedDigit()
        }
        .font(.system(size: 13, weight: total ? .bold : .regular))
        .foregroundStyle(total ? Color.white : Color(hex: 0xD8CDEB))
        .padding(.vertical, 5)
        .padding(.top, total ? 4 : 0)
        .overlay(alignment: .top) { if total { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1) } }
    }

    // MARK: Setup and review

    private var setupCard: some View {
        WalletCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.vib300)
                        .frame(width: 38, height: 38)
                        .background(Theme.vib500.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Budget setup").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("Create or edit pockets: monthly amount, and an optional goal amount and date.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                HStack(spacing: 8) {
                    Button { suggestOnOpen = false; showSetup = true } label: {
                        Text("Edit pockets").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(LinearGradient(colors: [Theme.vib500, Theme.vib700], startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Theme.vib500.opacity(0.35), radius: 9)
                    }
                    Button { suggestOnOpen = true; showSetup = true } label: {
                        HStack(spacing: 7) {
                            AIRing(size: 14, ring: 3.5)
                            Text("AI suggest amounts")
                        }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib100)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
                    }
                }
            }
        }
    }

    private var reviewCard: some View {
        AICard {
            VStack(alignment: .leading, spacing: 10) {
                AILabel(title: "Review", note: review.isEmpty ? "all clear" : "\(review.count) to check")
                if review.isEmpty {
                    Text("Nothing flagged. Run the month-end check in More to have the Accountant look.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.muted)
                }
                ForEach(review) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Spacer()
                            if let m = item.month { Text(DateParse.monthLabel(m)).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                        }
                        Text(item.detail).font(.system(size: 12)).foregroundStyle(Theme.cardText).fixedSize(horizontal: false, vertical: true)
                        if item.kind == "unsorted", let d = data {
                            Menu {
                                ForEach(d.spending.pockets.map(\.name) + d.savings.filter { $0.kind == "saving" }.map(\.name), id: \.self) { name in
                                    Button(name) { Task { await resolve(item, "confirmed", pocket: name) } }
                                }
                            } label: {
                                Chip(text: item.pocket.map { "Use \($0)" } ?? "Pick a pocket…")
                            }
                        }
                        HStack(spacing: 8) {
                            if item.kind != "unsorted" || item.pocket != nil {
                                Button { Task { await resolve(item, "confirmed") } } label: { Chip(text: "Confirm") }
                            }
                            Button { Task { await resolve(item, "dismissed") } } label: { Chip(text: "Dismiss", color: Theme.muted) }
                        }
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).offset(y: -4) }
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        do {
            data = try await api.get("wallet")
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

    private func resolve(_ item: ReviewItem, _ status: String, pocket: String? = nil) async {
        var body: [String: Any] = ["status": status]
        if let pocket { body["pocket"] = pocket }
        let _: OK? = try? await api.post("review/\(item.id)/resolve", body: body)
        review.removeAll { $0.id == item.id }
        if pocket != nil { await load() }
    }

    private func undo(_ move: PocketMove) async {
        let _: OK? = try? await api.post("moves/\(move.id)/undo")
        await load()
    }
}

// MARK: - Pieces

/// The render's wallet card (a little less padding than Card).
struct WalletCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(EdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// "$100,482.36" with grey cents.
struct SplitAmount: View {
    let value: Double
    var size: CGFloat = 24

    var body: some View {
        let parts = Money.usd(value).split(separator: ".")
        (Text(parts.first.map(String.init) ?? "")
            + Text(parts.count > 1 ? "." + parts[1] : "").foregroundColor(Theme.muted).fontWeight(.semibold))
            .font(.system(size: size, weight: .bold))
            .tracking(size > 28 ? -0.6 : -0.3)
            .monospacedDigit()
            .foregroundStyle(Theme.text)
    }
}

/// A brand-colored badge for each institution (initials, not the real trademarked logos).
struct InstitutionLogo: View {
    let institution: String
    var size: CGFloat = 32

    static func color(_ name: String) -> Color {
        switch name {
        case "Chase": return Color(hex: 0x2F8CFF)
        case "Bank of America": return Color(hex: 0xE0314B)
        case "BCA": return Color(hex: 0x1F6FD1)
        case "Mandiri": return Color(hex: 0xF2B21B)
        case "Jago": return Color(hex: 0xFFC21A)
        default: return Color(hex: 0xA45CFF)  // the portfolio
        }
    }

    static func shortName(_ name: String) -> String {
        switch name {
        case "Bank of America": return "BofA"
        case "Fidelity": return "Portfolio"
        default: return name
        }
    }

    private var style: (colors: [Color], text: String?, icon: String?, ink: Color) {
        switch institution {
        case "Chase": return ([Color(hex: 0x2F8CFF), Color(hex: 0x0B3F8C)], "C", nil, .white)
        case "Bank of America": return ([Color(hex: 0xE0314B), Color(hex: 0x012169)], "BofA", nil, .white)
        case "BCA": return ([Color(hex: 0x2A7DE1), Color(hex: 0x0B3B7A)], "BCA", nil, .white)
        case "Mandiri": return ([Color(hex: 0x123E7C), Color(hex: 0x0A2552)], "M", nil, Color(hex: 0xF7B500))
        case "Jago": return ([Color(hex: 0xFFC94A), Color(hex: 0xF29B00)], "J", nil, Color(hex: 0x1A1305))
        default: return ([Color(hex: 0xA45CFF), Color(hex: 0x4B1A8C)], nil, "chart.line.uptrend.xyaxis", .white)
        }
    }

    var body: some View {
        let s = style
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(LinearGradient(colors: s.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            if let icon = s.icon {
                Image(systemName: icon).font(.system(size: size * 0.48, weight: .bold)).foregroundStyle(s.ink)
            } else if let text = s.text {
                Text(text).font(.system(size: text.count > 2 ? size * 0.32 : size * 0.44, weight: .heavy))
                    .tracking(-0.3).foregroundStyle(s.ink)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(institution)
    }
}

struct InstitutionRow: View {
    let group: Institution

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                InstitutionLogo(institution: group.institution)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.kind == "investment" ? "Portfolio" : group.institution)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(group.kind == "investment" ? "\(group.institution) brokerage" :
                            group.accounts.map { "\($0.name) ••\($0.mask ?? "")" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                if group.country == "ID" { Text("🇮🇩").font(.system(size: 12)) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x6F6683))
            }
            HStack(alignment: .firstTextBaseline) {
                SplitAmount(value: group.totalUsd, size: 21)
                if group.currency != "USD" {
                    Text(Money.format(group.totalLocal, currency: group.currency)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

struct DebtRow: View {
    let debt: Debt

    private var kind: String { debt.kind ?? "card" }

    private var title: String {
        switch kind {
        case "mortgage": "\(InstitutionLogo.shortName(debt.institution)) mortgage"
        case "loan": "\(InstitutionLogo.shortName(debt.institution)) loan"
        case "installment": debt.name
        default: "\(InstitutionLogo.shortName(debt.institution)) credit card"
        }
    }

    private var subtitle: String {
        switch kind {
        case "installment": "Installment plan on \(InstitutionLogo.shortName(debt.institution)) ••\(debt.mask ?? "")"
        default: "\(debt.name) ••\(debt.mask ?? "")"
        }
    }

    var body: some View {
        let color = InstitutionLogo.color(debt.institution)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                InstitutionLogo(institution: debt.institution)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x6F6683))
            }
            SplitAmount(value: debt.owed, size: 21).padding(.top, 8)
            HStack {
                if let next = debt.nextAutopay {
                    Text("\(kind == "card" ? "Autopay" : "Next payment") \(DateParse.shortDay(next))")
                        .foregroundStyle(Theme.warn).fontWeight(.semibold)
                }
                Spacer()
                if let pct = debt.pctOfLimit, let limit = debt.limit {
                    Text("\(Int(pct.rounded()))% of \(Money.whole(limit)) limit").foregroundStyle(Theme.muted)
                } else if let detail = debt.detail {
                    Text(detail).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .padding(.top, 8)
            if let bar = kind == "installment" ? debt.progressPct : debt.pctOfLimit {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(color).frame(width: geo.size.width * min(1, bar / 100))
                    }
                }
                .frame(height: 4)
                .padding(.top, 6)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}

struct PocketRow: View {
    let name: String
    let color: Color
    let value: String
    let sub: String?
    let suffix: String?
    let over: Bool
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                GlowDot(color: color, size: 8)
                Text(name).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer()
                (Text(value).fontWeight(.semibold).foregroundColor(over ? Theme.over : Theme.text)
                    + Text(suffix.map { " \($0)" } ?? "").foregroundColor(Theme.muted))
                    .font(.system(size: 13)).monospacedDigit()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(hex: 0x6F6683))
            }
            if let sub {
                Text(sub).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.leading, 17).padding(.top, 3)
            }
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(color).frame(width: geo.size.width * min(1, max(0, progress)))  // over: full, same color
                    }
                }
                .frame(height: 4)
                .padding(.leading, 17)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, over ? 10 : 0)
        .background {
            if over {  // over budget: the whole row gets a light red highlight; the amount stays red
                RoundedRectangle(cornerRadius: 12).fill(Theme.over.opacity(0.11))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.over.opacity(0.25), lineWidth: 1))
            }
        }
        .padding(.horizontal, over ? -10 : 0)  // the tint reaches a little past the text, not the card edges
        .padding(.vertical, over ? 3 : 0)
        .overlay(alignment: .bottom) { if !over { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) } }
    }
}

/// "● BofA 18%  ● Chase 22%  ● Portfolio 60%" that wraps when it doesn't fit.
struct FlowKey: View {
    let items: [(String, Color, Double)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { key($0.element) } }
                HStack(spacing: 12) { ForEach(Array(items.dropFirst(3).enumerated()), id: \.offset) { key($0.element) } }
            }
        }
    }

    private var content: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { key($0.element) }
    }

    private func key(_ item: (String, Color, Double)) -> some View {
        HStack(spacing: 5) {
            Circle().fill(item.1).frame(width: 7, height: 7)
            Text("\(item.0) \(item.2 > 0 && item.2 < 1 ? "<1" : String(Int(item.2.rounded())))%")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.muted)
    }
}
