import SwiftUI

/// Home, built from the render: total balance, AI Summary, Cash flow Sankey,
/// Remaining Budget, Savings and AI next steps.
struct HomeView: View {
    var reloadToken = 0
    var openTab: (AppTab) -> Void = { _ in }

    @State private var data: HomeData?
    @State private var month = ""
    @State private var error: String?
    @State private var revealed = false
    @AppStorage("hideBalances") private var hideBalances = false
    @Environment(\.scenePhase) private var scenePhase

    private let api = APIClient()
    private var hidden: Bool { hideBalances && !revealed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let data {
                    balanceHeader(data.balance)
                    aiSummary(data)
                    cashflowCard(data)
                    divider
                    remainingBudget(data)
                    savings(data.savings)
                    nextSteps(data)
                } else if let error {
                    BackendErrorCard(message: error)
                } else {
                    ProgressView().tint(Theme.vib400).frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 180)
        }
        .scrollIndicators(.hidden)
        .refreshable { await load() }
        .task(id: "\(month)-\(reloadToken)") { await load() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { revealed = false } }  // hide again next time
    }

    // MARK: Sections

    private func balanceHeader(_ b: BalanceInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Total Balance")
                if hideBalances { Image(systemName: hidden ? "eye.slash" : "eye").font(.system(size: 13)) }
            }
            .font(.system(size: 15)).foregroundStyle(Theme.muted).padding(.bottom, 4)
            // Hide balances (More → Privacy): "$***,***.**" until tapped; tap again to hide.
            let parts = Money.masked(Money.usd(b.total), hidden).split(separator: ".")
            (Text(parts.first.map(String.init) ?? "")
                + Text(parts.count > 1 ? "." + parts[1] : "").foregroundColor(Theme.muted).fontWeight(.semibold))
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            HStack(spacing: 10) {
                Chip(text: "\(b.change >= 0 ? "▲" : "▼") \(Money.masked(Money.usd(abs(b.change)), hidden)) · \(abs(b.changePct).formatted(.number.precision(.fractionLength(1)).locale(Money.locale)))%")
                Text("this month · \(b.accounts) accounts").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .padding(.top, 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard hideBalances else { return }
            withAnimation(.easeOut(duration: 0.25)) { revealed.toggle() }
        }
        .accessibilityLabel(hidden ? "Total balance hidden. Double-tap to show." : "Total balance \(Money.usd(b.total))")
    }

    private func aiSummary(_ d: HomeData) -> some View {
        let s = d.summary
        let range = "\(DateParse.shortDay(d.month + "-01"))–\(max(1, d.budget.daysElapsed))"  // e.g. "Oct 1–24"
        return AICard {
            VStack(alignment: .leading, spacing: 0) {
                AILabel(title: "AI Summary", note: range)
                VStack(alignment: .leading, spacing: 4) {
                    insightRow(color: Theme.vib400) {
                        Text("Spent ") + Text(Money.whole(s.spent)).bold().foregroundColor(.white)
                            + Text(" of your ") + Text(Money.whole(s.budget)).bold().foregroundColor(.white)
                            + Text(" budget, ") + Text(Money.whole(s.left)).bold().foregroundColor(.white) + Text(" left")
                    }
                    insightRow(color: Color(hex: 0x4F8DFF)) {
                        Text("About ") + Text("\(Money.whole(s.spendPerDayLast7Days))/day").bold().foregroundColor(.white)
                            + Text(" for the last 7 days")
                    }
                    if let insight = s.insight {
                        insightRow(color: Color(hex: 0xFF8A4C)) {
                            Text(insight).foregroundColor(Theme.warn).fontWeight(.semibold)
                        }
                    }
                }
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.cardText)
                budgetBar(used: s.pctUsed, expected: s.pctExpected)
                HStack {
                    Text("\(Int(s.pctUsed.rounded()))% of budget used")
                    Spacer()
                    Text("Expected by today: \(Int(s.pctExpected.rounded()))%")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 16)
    }

    private func insightRow(color: Color, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            GlowDot(color: color).offset(y: -2)
            text()
        }
    }

    private func budgetBar(used: Double, expected: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.vib500, Theme.vib400, Color(hex: 0xFF8A4C)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(1, used / 100))
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.8))
                    .frame(width: 2, height: 12)
                    .offset(x: geo.size.width * min(1, expected / 100) - 1)
            }
        }
        .frame(height: 6)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func cashflowCard(_ d: HomeData) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cash flow").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                        Text("In \(Money.whole(d.cashflow.totalIn)) · Spent \(Money.whole(d.cashflow.spent))")
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    MonthMenu(months: d.months, selected: $month)
                }
                if d.cashflow.totalIn > 0 || d.cashflow.totalOut > 0 {
                    SankeyView(cashflow: d.cashflow).frame(height: 340)
                } else {
                    Text("Nothing recorded for this month yet.").font(.footnote).foregroundStyle(Theme.muted).padding(.vertical, 30)
                }
            }
        }
        .padding(.top, 14)
    }

    private var divider: some View {
        LinearGradient(colors: [.clear, Theme.vib400.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .padding(.top, 24)
            .padding(.bottom, 20)
    }

    private func remainingBudget(_ d: HomeData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remaining Budget").font(.system(size: 20, weight: .bold)).tracking(-0.2).foregroundStyle(Theme.text)
                    Text("\(Money.whole(d.budget.totalLeft)) left of \(Money.whole(d.budget.totalBudget)) · \(d.budget.daysToGo) days to go")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                Spacer()
                MonthMenu(months: d.months, selected: $month)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(d.budget.pockets) { BudgetCard(pocket: $0) }
            }
        }
    }

    private func savings(_ pockets: [SavingsPocket]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Savings").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text("\(pockets.count) pockets · \(Money.whole(pockets.reduce(0) { $0 + $1.total })) set aside")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("See all ›") { openTab(.wallet) }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(pockets.filter { $0.kind == "saving" }) { SavingsCard(pocket: $0, month: month) }
            }
            ForEach(pockets.filter { $0.kind == "investing" }) { SavingsCard(pocket: $0, month: month, wide: true) }
        }
        .padding(.top, 22)
    }

    private func nextSteps(_ d: HomeData) -> some View {
        AICard {
            VStack(alignment: .leading, spacing: 0) {
                AILabel(title: "AI Summary", note: "\(d.nextSteps.count) next steps")
                if d.nextSteps.isEmpty {
                    Text("Nothing needs your attention.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                ForEach(Array(d.nextSteps.enumerated()), id: \.offset) { i, step in
                    NextStepRow(step: step) {
                        switch step.action {
                        case "view": openTab(step.title.localizedCaseInsensitiveContains("portfolio") ? .invest : .wallet)
                        default: openTab(.wallet)
                        }
                    }
                    .padding(.top, i == 0 ? 2 : 10)
                    .padding(.bottom, i == d.nextSteps.count - 1 ? 0 : 10)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                    }
                }
            }
        }
        .padding(.top, 18)
    }

    // MARK: Data

    private func load() async {
        do {
            let d: HomeData = try await api.get("home", query: month.isEmpty ? [:] : ["month": month])
            data = d
            if month.isEmpty { month = d.month }
            error = nil
            await checkAlerts(d)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension HomeView {
    /// Over-budget and "salary not received" alerts (More → Notifications), for the current month.
    fileprivate func checkAlerts(_ d: HomeData) async {
        guard d.month == String(d.today.prefix(7)) else { return }
        let over = d.budget.pockets.filter(\.over).map(\.name)
        let salaryMissing = d.salary?.missing ?? false  // 2 days after the payday set in Profile
        NotificationPrefs.checkAlerts(month: d.month, overPockets: over, salaryMissing: salaryMissing)
    }
}

struct BudgetCard: View {
    let pocket: BudgetPocket

    var body: some View {
        let color = Theme.category(pocket.name)
        let used = pocket.available > 0 ? min(1, pocket.spent / pocket.available) : 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PocketIcon(name: pocket.name)
                Text(pocket.name).lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color(hex: 0xD8CDEB))
            HStack {
                Text(pocket.over ? "−" + Money.whole(-pocket.left) : Money.whole(pocket.left))
                    .foregroundStyle(pocket.over ? Theme.over : Theme.text)
                Spacer()
                if pocket.over { Tag(text: "Over", over: true) } else if pocket.paid { Tag(text: "Paid") }
            }
            .font(.system(size: 22, weight: .bold))
            .monospacedDigit()
            .padding(.top, 10)
            Text(pocket.over ? "over the \(Money.whole(pocket.available)) budget" : "left of \(Money.whole(pocket.available))")
                .font(.system(size: 11.5)).foregroundStyle(Theme.muted).padding(.top, 1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(color).frame(width: geo.size.width * used)  // over: full width, same color
                }
            }
            .frame(height: 4)
            .padding(.top, 10)
        }
        .padding(12)
        .background {
            ZStack {  // over budget: a light red tint on the whole card, under the text
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.cardFill)
                if pocket.over { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.over.opacity(0.11)) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(pocket.over ? Theme.over.opacity(0.25) : Theme.hairline, lineWidth: 1))
    }
}

/// A savings or investing pocket: total saved (or ready to invest) and this month's set-aside.
struct SavingsCard: View {
    let pocket: SavingsPocket
    var month = ""
    var wide = false

    var body: some View {
        let color = Theme.category(pocket.name)
        let monthShort = month.isEmpty ? "This month" : String(DateParse.monthLabel(month).prefix(3))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                PocketIcon(name: pocket.name)
                Text(pocket.name).lineLimit(1)
                if wide, let amount = pocket.monthlyAmount {
                    Spacer()
                    Tag(text: "\(monthShort) +\(Money.whole(pocket.thisMonth)) of \(Money.whole(amount))\(pocket.thisMonth >= amount ? " ✓" : "")")
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Color(hex: 0xD8CDEB))
            if wide {
                Text("READY TO INVEST").font(.system(size: 11)).tracking(0.4).foregroundStyle(Theme.muted).padding(.top, 8)
            }
            Text(Money.whole(pocket.total))
                .font(.system(size: 22, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                .padding(.top, wide ? 2 : 10)
            if !wide {
                if let goal = pocket.goal, let pct = pocket.pctOfGoal {
                    Text("\(Int(pct.rounded()))% of \(Money.whole(goal)) goal")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted).padding(.top, 1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(color).frame(width: geo.size.width * min(1, pct / 100))
                        }
                    }
                    .frame(height: 4)
                    .padding(.top, 10)
                } else {
                    Text("No goal set").font(.system(size: 11.5)).foregroundStyle(Theme.muted).padding(.top, 1)
                }
                HStack {
                    if pocket.thisMonth > 0 { Tag(text: "\(monthShort) +\(Money.whole(pocket.thisMonth)) ✓") }
                }
                .frame(minHeight: 18)
                .padding(.top, 9)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct NextStepRow: View {
    let step: NextStep
    let onTap: () -> Void

    var body: some View {
        let (icon, color): (String, Color) = {
            switch step.action {
            case "review": return ("doc.text", Color(hex: 0xFF8A4C))
            case "fix": return ("exclamationmark.triangle", Color(hex: 0xFF6B6B))
            default: return step.title.localizedCaseInsensitiveContains("portfolio")
                ? ("chart.pie", Color(hex: 0x4F8DFF)) : ("chart.line.uptrend.xyaxis", Color(hex: 0x2FD39B))
            }
        }()
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(AIMarkdown.attributed(step.detail)).font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onTap) { Chip(text: step.action.capitalized) }
                .frame(maxHeight: .infinity)
        }
    }
}

struct BackendErrorCard: View {
    let message: String
    @State private var address = UserDefaults.standard.string(forKey: APIClient.addressKey) ?? ""
    @State private var saved = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Can't reach the backend").font(.headline).foregroundStyle(Theme.text)
                Text("On the Mac, start it (see the README). On an iPhone, enter the Mac's address:")
                    .font(.caption).foregroundStyle(Theme.muted)
                HStack {
                    TextField("http://Your-Mac.local:8000", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(8).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    Button(saved ? "Saved" : "Save") {
                        if let url = APIClient.normalized(address) {
                            UserDefaults.standard.set(url.absoluteString, forKey: APIClient.addressKey)
                            address = url.absoluteString
                            saved = true
                        }
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.vib500)
                }
                if saved { Text("Saved. Pull down to reload.").font(.caption).foregroundStyle(Theme.positive) }
                Text("Now trying \(APIClient.baseURL.absoluteString) · \(message)").font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 40)
    }
}

#Preview {
    ZStack { Theme.background; HomeView() }.preferredColorScheme(.dark)
}
