import SwiftUI

/// Budget setup (Wallet → Edit pockets), as decided 2026-10-25 (PLAN.md → "Budget setup").
/// Top card: expected income, the plan split into spending / saving / investing / not planned,
/// "Not planned yet" and "Unspent this month" in $ and %, and when changes apply. Then Income,
/// Spending, Savings and Investing: tap a row to edit it ($ and % of income linked both ways),
/// "+ Add … pocket" at the end of each section, Archive asks where the money goes. Nothing is
/// saved until Save; a plan over income asks which savings pocket covers the extra.
/// With no pockets yet it opens on the first-time choice (AI draft or start from scratch).
struct BudgetSetupSheet: View {
    var suggestOnOpen = false

    @Environment(\.dismiss) private var dismiss
    @State private var plan: BudgetPlan?
    @State private var edits: [EditPocket] = []
    @State private var expanded: String?
    @State private var apply = "this_month"
    @State private var adding: String?          // kind of the Add form that's open
    @State private var archiving: EditPocket?
    @State private var overIncome: OverIncomeReply?
    @State private var suggestions: [String: BudgetSuggestionResult.Item] = [:]
    @State private var suggestionNote: String?
    @State private var working: String?          // "suggest" / "draft" while the Advisor runs
    @State private var steps: [AgentEvent] = []
    @State private var draftNote: String?
    @State private var setupChosen = false       // first time: past the choice screen
    @State private var confirmStartOver = false
    @State private var saving = false
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let plan {
                        if plan.firstTime && !setupChosen {
                            FirstTimeChoice(plan: plan, working: working == "draft", steps: steps) { useAI in
                                Task { await startFirstTime(useAI: useAI) }
                            }
                        } else {
                            summaryCard(plan)
                            if let draftNote { AICard { Text(draftNote).font(.system(size: 13)).foregroundStyle(Theme.cardText) } }
                            ForEach(["income", "spending", "saving", "investing"], id: \.self) { section(plan, $0) }
                            footer(plan)
                        }
                    } else if let error {
                        BackendErrorCard(message: error)
                    } else {
                        ProgressView().tint(Theme.vib400).frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if let error, plan != nil {
                        Text(error).font(.system(size: 13)).foregroundStyle(Theme.over)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Budget setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save(coverFrom: nil) } }
                        .disabled(saving || plan == nil || (plan?.firstTime == true && !setupChosen))
                }
            }
        }
        .tint(Theme.vib400)
        .interactiveDismissDisabled(hasChanges)  // unsaved edits: leave with Cancel or Save
        .task {
            await load()
            if suggestOnOpen, plan?.firstTime == false { await suggest() }
        }
        .sheet(item: Binding(get: { adding.map { AddKind(kind: $0) } }, set: { adding = $0?.kind })) { k in
            AddPocketSheet(kind: k.kind, income: income, notPlanned: notPlanned, taken: Set(edits.map { $0.name.lowercased() }),
                           catalog: (plan?.catalog ?? []).filter { $0.kind == k.kind && !edits.map(\.name).contains($0.name) },
                           accounts: plan?.accounts ?? [], frequencies: plan?.frequencies ?? []) { new in
                edits.append(new)
            }
        }
        .sheet(item: $archiving) { p in
            ArchiveSheet(pocket: p, others: edits.filter { $0.key != p.key && !$0.isNew && sameFamily($0.kind, p.kind) }) { moveTo in
                Task { await archive(p, moveTo: moveTo) }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { overIncome }, set: { overIncome = $0 })) { reply in
            OverIncomeSheet(reply: reply) { source in
                overIncome = nil
                Task { await save(coverFrom: source) }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var hasChanges: Bool {
        guard let plan else { return false }
        return edits.contains { $0.payload(plan: plan) != nil } || edits.count != plan.pockets.count
    }

    // MARK: Numbers (from the edits, so they move as you type)

    private var income: Double { edits.filter { $0.kind == "income" }.reduce(0) { $0 + $1.monthly } }
    private func planned(_ kind: String) -> Double { edits.filter { $0.kind == kind }.reduce(0) { $0 + $1.monthly } }
    private var notPlanned: Double { income - planned("spending") - planned("saving") - planned("investing") }

    /// Spending budgets still left this month. "This month" changes move it; "From next month" doesn't.
    private var unspent: (left: Double, available: Double) {
        var left = 0.0, available = 0.0
        for e in edits where e.kind == "spending" {
            let delta = apply == "this_month" ? e.monthly - (e.original?.monthly ?? 0) : 0
            let l = (e.original?.left ?? 0) + (e.isNew ? (apply == "this_month" ? e.monthly : 0) : delta)
            left += max(0, l)
            available += (e.original?.available ?? 0) + (e.isNew ? (apply == "this_month" ? e.monthly : 0) : delta)
        }
        return (left, available)
    }

    private func pct(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "–" }
        return "\((100 * part / whole).formatted(.number.precision(.fractionLength(0))))%"
    }

    // MARK: Top card

    private func summaryCard(_ plan: BudgetPlan) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Expected income").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        Text("\(Money.plain(income))/mo").font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(Theme.text)
                    }
                    Spacer()
                }
                PlanBar(income: income, parts: [("Spending", planned("spending"), Theme.vib400),
                                                 ("Saving", planned("saving"), Theme.positive),
                                                 ("Investing", planned("investing"), Color(hex: 0x2F8CFF))])
                HStack(spacing: 10) {
                    let over = notPlanned < -0.005
                    StatTile(title: "Not planned yet", value: over ? "−\(Money.usd(-notPlanned))" : Money.usd(notPlanned),
                             detail: over ? "over income" : "\(pct(notPlanned, of: income)) of income", alert: over)
                    let u = unspent
                    StatTile(title: "Unspent this month", value: Money.usd(u.left),
                             detail: "\(pct(u.left, of: u.available)) of the spending budget", alert: false)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes apply").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Picker("Changes apply", selection: $apply) {
                        Text("This month").tag("this_month")
                        Text("From next month").tag("next_month")
                    }
                    .pickerStyle(.segmented)
                }
                Button { Task { await suggest() } } label: {
                    HStack(spacing: 8) {
                        AIRing(size: 16, ring: 4)
                        Text(working == "suggest" ? "The Advisor is looking at your spending…" : "AI suggest amounts")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .disabled(working != nil)
                if working == "suggest" { AgentActivity(steps: steps) }
                if let suggestionNote { Text(suggestionNote).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
        }
    }

    // MARK: Sections

    private static let titles = ["income": "Income", "spending": "Spending", "saving": "Savings", "investing": "Investing"]
    private static let addLabels = ["income": "+ Add income pocket", "spending": "+ Add spending pocket",
                                    "saving": "+ Add savings pocket", "investing": "+ Add investing pocket"]

    private func section(_ plan: BudgetPlan, _ kind: String) -> some View {
        let rows = edits.indices.filter { edits[$0].kind == kind }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Self.titles[kind] ?? kind).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer()
                let total = rows.reduce(0.0) { $0 + edits[$1].monthly }
                Text("\(Money.plain(total))/mo").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            VStack(spacing: 0) {
                ForEach(rows, id: \.self) { i in
                    PocketEditRow(pocket: $edits[i], income: income, plan: plan, apply: apply,
                                  expanded: expanded == edits[i].key, suggestion: suggestions[edits[i].original?.name ?? ""],
                                  onTap: { withAnimation(.snappy) { expanded = expanded == edits[i].key ? nil : edits[i].key } },
                                  onArchive: {
                                      if edits[i].isNew { edits.remove(at: i); expanded = nil } else { archiving = edits[i] }
                                  })
                    Divider().overlay(Theme.hairline)
                }
                Button { adding = kind } label: {
                    HStack {
                        Text(Self.addLabels[kind] ?? "+ Add").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.vib300)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 14)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private func footer(_ plan: BudgetPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rate = plan.fx.idrPerUsd, let asOf = plan.fx.asOf {
                Text("Pockets are in US dollars. Money in rupiah (BCA, Mandiri, Jago, cash in IDR) is converted at Rp \(Int(rate).formatted()) = $1, the rate of \(DateParse.mediumDay(asOf)).")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Button("Start over…") { confirmStartOver = true }
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.over)
                .confirmationDialog("Start over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
                    Button("Switch off all pockets", role: .destructive) { Task { await startOver() } }
                } message: {
                    Text("For testing and the demo: every pocket is switched off, so setup starts fresh (AI draft or from scratch). Your transactions stay. Reset sample data in More brings the sample back.")
                }
        }
        .padding(.top, 4)
    }

    private func sameFamily(_ a: String, _ b: String) -> Bool {
        a == b || (a != "spending" && a != "income" && b != "spending" && b != "income")
    }

    // MARK: Loading and saving

    private func load() async {
        do {
            let p: BudgetPlan = try await api.get("budget")
            plan = p
            edits = p.pockets.map(EditPocket.init(from:))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(coverFrom: String?) async {
        guard let plan else { return }
        saving = true
        error = nil
        var body: [String: Any] = ["apply": apply, "pockets": edits.compactMap { $0.payload(plan: plan) }]
        if let coverFrom { body["cover_from"] = coverFrom }
        do {
            let (status, data) = try await api.send("budget/save", body: body)
            switch status {
            case 200:
                saving = false
                dismiss()
                return
            case 409:
                overIncome = try api.decodeBody(data, as: OverIncomeReply.self)
            default:
                let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
                error = detail ?? "Couldn't save (\(status))."
            }
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }

    private func archive(_ p: EditPocket, moveTo: String?) async {
        archiving = nil
        do {
            let (status, data) = try await api.send("budget/pockets/\(p.original?.name ?? p.name)/archive",
                                                    body: moveTo.map { ["move_to": $0] } ?? [:])
            guard status == 200 else {
                error = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String) ?? "Couldn't archive."
                return
            }
            // Keep everything else being edited; refresh the numbers from the server.
            let pending = edits.filter { $0.key != p.key }
            let fresh: BudgetPlan = try await api.get("budget")
            plan = fresh
            edits = pending.map { e in
                guard !e.isNew, let o = fresh.pockets.first(where: { $0.name == e.original?.name }) else { return e }
                var updated = e
                updated.original = o
                return updated
            }
            expanded = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggest() async {
        working = "suggest"
        steps = []
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            let r: BudgetSuggestionResult = try await api.post("agents/suggest-budget")
            if let s = r.suggestion {
                suggestions = Dictionary(s.suggestions.map { ($0.pocket, $0) }, uniquingKeysWith: { a, _ in a })
                suggestionNote = s.note
            }
        } catch {
            self.error = error.localizedDescription
        }
        watcher.cancel()
        working = nil
    }

    private func startFirstTime(useAI: Bool) async {
        guard useAI else {
            edits = []
            setupChosen = true
            return
        }
        working = "draft"
        steps = []
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            let r: BudgetDraftResult = try await api.post("agents/draft-budget")
            if let d = r.draft {
                edits = d.income.map { EditPocket.new(name: $0.name, kind: "income", monthly: $0.expectedMonthly,
                                                      frequency: $0.frequency, receivedIn: $0.receivedIn) }
                    + d.pockets.map { EditPocket.new(name: $0.name, kind: $0.kind, monthly: $0.monthlyAmount, goal: $0.goalAmount) }
                draftNote = "Drafted by the Advisor: \(d.note) Nothing is saved until you tap Save."
                setupChosen = true
            }
        } catch {
            self.error = error.localizedDescription
        }
        watcher.cancel()
        working = nil
    }

    private func startOver() async {
        let _: OK? = try? await api.post("budget/start-over")
        setupChosen = false
        draftNote = nil
        suggestions = [:]
        await load()
    }
}

private struct AddKind: Identifiable {
    let kind: String
    var id: String { kind }
}

extension OverIncomeReply: Identifiable {
    var id: Double { over }
}

// MARK: - The editable copy of a pocket

struct EditPocket: Identifiable, Equatable {
    var key: String               // the saved name, or "new-…" for one not saved yet
    var original: SetupPocket?
    var name: String
    var kind: String
    var monthly: Double
    var hasGoal: Bool
    var goal: Double?
    var goalMonth: Date
    var starting: Double
    var frequency: String?
    var receivedIn: String?
    var isNew: Bool
    var id: String { key }

    static func == (a: EditPocket, b: EditPocket) -> Bool {
        a.key == b.key && a.name == b.name && a.monthly == b.monthly && a.hasGoal == b.hasGoal && a.goal == b.goal
            && a.goalMonth == b.goalMonth && a.starting == b.starting && a.frequency == b.frequency && a.receivedIn == b.receivedIn
    }

    init(from p: SetupPocket) {
        key = p.name
        original = p
        name = p.displayName
        kind = p.kind
        monthly = p.monthly
        hasGoal = p.goalAmount != nil
        goal = p.goalAmount
        goalMonth = p.goalDate.map { DateParse.day("\($0)-01") } ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!
        starting = p.startingAmount ?? 0
        frequency = p.frequency
        receivedIn = p.receivedIn
        isNew = false
    }

    static func new(name: String, kind: String, monthly: Double, goal: Double? = nil, starting: Double = 0,
                    goalMonth: Date? = nil, frequency: String? = nil, receivedIn: String? = nil) -> EditPocket {
        EditPocket(key: "new-\(UUID().uuidString)", original: nil, name: name, kind: kind, monthly: monthly,
                   hasGoal: goal != nil, goal: goal,
                   goalMonth: goalMonth ?? Calendar.current.date(byAdding: .year, value: 1, to: .now)!,
                   starting: starting, frequency: frequency ?? (kind == "income" ? "monthly" : nil),
                   receivedIn: receivedIn, isNew: true)
    }

    private init(key: String, original: SetupPocket?, name: String, kind: String, monthly: Double, hasGoal: Bool,
                 goal: Double?, goalMonth: Date, starting: Double, frequency: String?, receivedIn: String?, isNew: Bool) {
        self.key = key; self.original = original; self.name = name; self.kind = kind; self.monthly = monthly
        self.hasGoal = hasGoal; self.goal = goal; self.goalMonth = goalMonth; self.starting = starting
        self.frequency = frequency; self.receivedIn = receivedIn; self.isNew = isNew
    }

    var goalMonthString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: goalMonth)
    }

    /// What POST /budget/save needs for this pocket, or nil if nothing changed.
    func payload(plan: BudgetPlan) -> [String: Any]? {
        var body: [String: Any] = ["kind": kind, "monthly": (monthly * 100).rounded() / 100]
        if isNew {
            body["name"] = name.trimmingCharacters(in: .whitespaces)
            body["is_new"] = true
            body["starting_amount"] = starting
        } else if let o = original {
            body["name"] = o.name
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed != o.displayName { body["new_name"] = trimmed }
            let goalChanged = kind == "saving" && ((hasGoal ? goal : nil) != o.goalAmount || (hasGoal ? goalMonthString : nil) != o.goalDate)
            let incomeChanged = kind == "income" && (frequency != o.frequency || receivedIn != o.receivedIn)
            if abs(monthly - o.monthly) < 0.005 && body["new_name"] == nil && !goalChanged && !incomeChanged { return nil }
        }
        if kind == "saving" {
            body["goal_amount"] = hasGoal ? (goal ?? 0) : NSNull()
            body["goal_date"] = hasGoal ? goalMonthString : NSNull()
        }
        if kind == "income" {
            body["frequency"] = frequency ?? NSNull()
            body["received_in"] = receivedIn ?? NSNull()
        }
        return body
    }
}

// MARK: - Rows

struct PocketEditRow: View {
    @Binding var pocket: EditPocket
    let income: Double
    let plan: BudgetPlan
    let apply: String
    let expanded: Bool
    let suggestion: BudgetSuggestionResult.Item?
    let onTap: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onTap) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    GlowDot(color: Theme.category(pocket.original?.name ?? pocket.name), size: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(pocket.name.isEmpty ? "Untitled" : pocket.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.text)
                            if pocket.isNew { Tag(text: "New", over: false) }
                        }
                        Text(subline).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    Spacer()
                    Text("\(Money.plain(pocket.monthly))/mo").font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let s = suggestion, abs(s.monthlyAmount - pocket.monthly) > 0.5 {
                HStack(alignment: .top) {
                    Text("AI: \(Money.whole(s.monthlyAmount))/mo · \(s.reason)").font(.system(size: 12)).foregroundStyle(Theme.vib300)
                    Spacer()
                    Button("Use") { pocket.monthly = s.monthlyAmount }.font(.system(size: 12, weight: .semibold))
                }
                .padding(.bottom, expanded ? 0 : 10)
            }
            if expanded { editor.padding(.bottom, 12) }
        }
    }

    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    private var subline: String {
        let pct = income > 0 ? "\((100 * pocket.monthly / income).formatted(.number.precision(.fractionLength(0))))% of income" : "–"
        var parts: [String] = []
        switch pocket.kind {
        case "income":
            parts.append(Self.sentence(pocket.frequency ?? "monthly"))
            if let label = plan.accounts.first(where: { $0.id == pocket.receivedIn })?.label { parts.append(label) }
            if let r = pocket.original?.receivedThisMonth, r > 0 { parts.append("\(Money.whole(r)) received this month") }
        case "spending":
            parts.append(pct)
            if let left = pocket.original?.left {
                let l = left + (apply == "this_month" ? pocket.monthly - (pocket.original?.monthly ?? 0) : 0)
                parts.append(l < 0 ? "\(Money.whole(-l)) over" : "\(Money.whole(l)) unspent")
            } else if pocket.isNew { parts.append(apply == "this_month" ? "starts this month" : "starts next month") }
        default:
            parts.append(pct)
            let saved = pocket.original?.saved ?? pocket.starting
            if pocket.kind == "saving", pocket.hasGoal, let g = pocket.goal, g > 0 {
                parts.append("\(Money.whole(saved)) of \(Money.whole(g))")
            } else {
                parts.append("\(Money.whole(saved)) \(pocket.kind == "investing" ? "set aside" : "saved")")
            }
        }
        if let o = pocket.original, abs(o.nextMonth - o.monthly) > 0.005, pocket.kind != "income" {
            parts.append("\(Money.whole(o.nextMonth)) from next month")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if pocket.isNew || pocket.original?.custom == true {
                LabeledField(label: "Name") {
                    TextField("Name", text: $pocket.name).multilineTextAlignment(.trailing)
                }
            }
            if pocket.kind == "income" {
                LabeledField(label: "Expected per month") { MoneyField(value: $pocket.monthly) }
                LabeledField(label: "How often") {
                    Picker("How often", selection: Binding(get: { pocket.frequency ?? "monthly" }, set: { pocket.frequency = $0 })) {
                        ForEach(plan.frequencies, id: \.self) { Text(PocketEditRow.sentence($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                LabeledField(label: "Received in") {
                    Picker("Received in", selection: Binding(get: { pocket.receivedIn ?? "" }, set: { pocket.receivedIn = $0.isEmpty ? nil : $0 })) {
                        Text("Not set").tag("")
                        ForEach(plan.accounts) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                }
            } else {
                LinkedAmountFields(monthly: $pocket.monthly, income: income)
            }
            if pocket.kind == "saving" {
                GoalFields(pocket: $pocket, income: income)
            }
            HStack {
                Button("Done", action: onTap).buttonStyle(.borderedProminent).tint(Theme.vib500)
                Spacer()
                if pocket.original?.name != "Other income" {
                    Button(pocket.isNew ? "Remove" : "Archive", role: .destructive, action: onArchive).buttonStyle(.bordered)
                }
            }
        }
        .font(.system(size: 14))
    }
}

/// $ per month and % of income, linked both ways: edit one and the other follows.
struct LinkedAmountFields: View {
    @Binding var monthly: Double
    let income: Double

    @State private var dollars = ""
    @State private var percent = ""
    @FocusState private var focus: Field?
    enum Field { case dollars, percent }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text("$").foregroundStyle(Theme.muted)
                TextField("0", text: $dollars).keyboardType(.decimalPad).focused($focus, equals: .dollars)
                Text("/mo").foregroundStyle(Theme.muted).font(.system(size: 12))
            }
            .fieldBox()
            HStack(spacing: 4) {
                TextField("0", text: $percent).keyboardType(.decimalPad).focused($focus, equals: .percent)
                    .disabled(income <= 0)
                Text("% of income").foregroundStyle(Theme.muted).font(.system(size: 12))
            }
            .fieldBox()
        }
        .monospacedDigit()
        .onAppear(perform: sync)
        .onChange(of: dollars) { _, new in
            guard focus == .dollars else { return }
            monthly = max(0, Double(new) ?? 0)
            percent = income > 0 ? Self.fmt(100 * monthly / income) : ""
        }
        .onChange(of: percent) { _, new in
            guard focus == .percent, income > 0 else { return }
            monthly = max(0, ((Double(new) ?? 0) * income / 100 * 100).rounded() / 100)
            dollars = Self.fmt(monthly)
        }
        .onChange(of: monthly) { _, _ in if focus == nil { sync() } }
    }

    private func sync() {
        dollars = Self.fmt(monthly)
        percent = income > 0 ? Self.fmt(100 * monthly / income) : ""
    }

    static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

struct MoneyField: View {
    @Binding var value: Double
    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            Text("$").foregroundStyle(Theme.muted)
            TextField("0", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
        }
        .monospacedDigit()
        .onAppear { text = value == 0 ? "" : LinkedAmountFields.fmt(value) }
        .onChange(of: text) { _, new in value = max(0, Double(new) ?? 0) }
    }
}

/// Savings: "Has a goal", goal amount and target month, and what's needed per month to get there.
struct GoalFields: View {
    @Binding var pocket: EditPocket
    let income: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Has a goal", isOn: $pocket.hasGoal).tint(Theme.vib500)
            if pocket.hasGoal {
                LabeledField(label: "Goal amount") {
                    MoneyField(value: Binding(get: { pocket.goal ?? 0 }, set: { pocket.goal = $0 }))
                }
                DatePicker("Reach it by", selection: $pocket.goalMonth, in: Date.now..., displayedComponents: .date)
                if let needed = neededPerMonth {
                    Text("Needed to reach the goal on time: \(Money.usd(needed))/mo (\(income > 0 ? (100 * needed / income).formatted(.number.precision(.fractionLength(0))) : "–")% of income)")
                        .font(.system(size: 12)).foregroundStyle(needed > pocket.monthly + 0.5 ? Theme.warn : Theme.positive)
                }
            }
        }
    }

    private var neededPerMonth: Double? {
        guard let goal = pocket.goal, goal > 0 else { return nil }
        let saved = pocket.original?.saved ?? pocket.starting
        return max(0, (goal - saved) / Double(monthsUntil(pocket.goalMonth)))
    }
}

/// Whole calendar months from this month to the target month (Oct 2026 → Oct 2027 is 12), at least 1.
func monthsUntil(_ target: Date) -> Int {
    let cal = Calendar.current
    let a = cal.dateComponents([.year, .month], from: .now), b = cal.dateComponents([.year, .month], from: target)
    return max(1, ((b.year ?? 0) - (a.year ?? 0)) * 12 + (b.month ?? 0) - (a.month ?? 0))
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            content
        }
    }
}

private extension View {
    func fieldBox() -> some View {
        padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Top card pieces

struct PlanBar: View {
    let income: Double
    let parts: [(String, Double, Color)]

    var body: some View {
        let used = parts.reduce(0) { $0 + $1.1 }
        let whole = max(income, used, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { name, value, color in
                        if value > 0 { Capsule().fill(color).frame(width: max(3, geo.size.width * value / whole)) }
                    }
                    if income > used { Capsule().fill(Color.white.opacity(0.12)) }
                }
            }
            .frame(height: 8)
            HStack(spacing: 8) {
                ForEach(parts, id: \.0) { name, value, color in
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text("\(name) \(income > 0 ? (100 * value / income).formatted(.number.precision(.fractionLength(0))) : "–")%")
                    }
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 6)
                    Text("Not planned")
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let alert: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(alert ? Theme.over : Theme.text)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(alert ? Theme.over : Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - First-time choice

struct FirstTimeChoice: View {
    let plan: BudgetPlan
    let working: Bool
    let steps: [AgentEvent]
    let onContinue: (Bool) -> Void

    @State private var useAI: Bool?

    var body: some View {
        let ai = useAI ?? plan.aiDraftAvailable
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your budget").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.text)
            Text("You don't have any pockets yet. How would you like to start?").font(.system(size: 14)).foregroundStyle(Theme.muted)
            option(selected: ai, enabled: plan.aiDraftAvailable, ai: true,
                   title: "Build my budget from my spending (AI)",
                   detail: plan.aiDraftAvailable
                       ? "The Advisor reads your last \(min(plan.historyMonths, 3)) months of bank history and drafts income, spending pockets and savings. You review and edit before anything is saved."
                       : (plan.aiDraftReason ?? "Not enough bank history yet."))
            option(selected: !ai, enabled: true, ai: false,
                   title: "Start from scratch",
                   detail: "An empty list: add income and pockets yourself, with suggestions.")
            if working { AgentActivity(steps: steps) }
            Button { onContinue(ai) } label: {
                Text(working ? "The Advisor is drafting…" : "Continue").font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent).tint(Theme.vib500)
            .disabled(working)
        }
    }

    private func option(selected: Bool, enabled: Bool, ai: Bool, title: String, detail: String) -> some View {
        Button { if enabled { useAI = ai } } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? Theme.vib400 : Theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if ai { AIRing(size: 14, ring: 3.5) }
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(enabled ? Theme.text : Theme.muted)
                    }
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? Theme.vib400.opacity(0.7) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Add a pocket

struct AddPocketSheet: View {
    let kind: String
    let income: Double
    let notPlanned: Double
    let taken: Set<String>
    let catalog: [SetupPocket]
    let accounts: [BudgetAccount]
    let frequencies: [String]
    let onAdd: (EditPocket) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var monthly = 0.0
    @State private var hasGoal = true
    @State private var goal = 0.0
    @State private var goalMonth = Calendar.current.date(byAdding: .year, value: 1, to: .now)!
    @State private var starting = 0.0
    @State private var frequency = "monthly"
    @State private var receivedIn = ""
    @State private var hint: BudgetHint.Hint?

    private let api = APIClient()
    private static let suggestions = [
        "spending": ["Coffee", "Entertainment", "Travel", "Gifts", "Shopping", "Subscriptions"],
        "saving": ["Holiday", "New laptop", "Wedding", "General Savings"],
        "investing": ["Ready to invest", "Retirement"],
        "income": ["Freelance", "Dividends", "Side job"],
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(chips, id: \.self) { c in
                                Button(c) { name = c }
                                    .font(.system(size: 13, weight: .semibold)).buttonStyle(.bordered).tint(Theme.vib400)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    if let nameProblem { Text(nameProblem).font(.footnote).foregroundStyle(Theme.over) }
                }
                switch kind {
                case "income":
                    Section {
                        LabeledField(label: "Expected per month (optional)") { MoneyField(value: $monthly) }
                        Picker("How often", selection: $frequency) { ForEach(frequencies, id: \.self) { Text(PocketEditRow.sentence($0)).tag($0) } }
                        Picker("Received in", selection: $receivedIn) {
                            Text("Not set").tag("")
                            ForEach(accounts) { Text($0.label).tag($0.id) }
                        }
                    } footer: { Text("The Accountant sorts matching deposits into it. Transfers between your accounts and refunds aren't income.") }
                default:
                    if kind == "saving" {
                        Section {
                            Toggle("Has a goal", isOn: $hasGoal).tint(Theme.vib500)
                            if hasGoal {
                                LabeledField(label: "Goal amount") { MoneyField(value: $goal) }
                                DatePicker("Reach it by", selection: $goalMonth, in: Date.now..., displayedComponents: .date)
                            }
                        }
                    }
                    if kind != "spending" {
                        Section { LabeledField(label: kind == "investing" ? "Already set aside" : "Already saved") { MoneyField(value: $starting) } }
                    }
                    Section {
                        LinkedAmountFields(monthly: $monthly, income: income)
                        if kind == "saving", hasGoal, let needed {
                            Text("Needed to reach the goal on time: \(Money.usd(needed))/mo (\(income > 0 ? (100 * needed / income).formatted(.number.precision(.fractionLength(0))) : "–")% of income)")
                                .font(.footnote).foregroundStyle(Theme.vib300)
                            Button("Use \(Money.usd(needed))/mo") { monthly = (needed * 100).rounded() / 100 }.font(.footnote.weight(.semibold))
                        }
                        if kind == "spending", let hint {
                            HStack {
                                Text("From your past spending: about \(Money.usd(hint.monthly))/mo (\(hint.matches) charges in \(hint.months) months)")
                                    .font(.footnote).foregroundStyle(Theme.vib300)
                                Spacer()
                                Button("Use") { monthly = (hint.monthly / 10).rounded(.up) * 10 }.font(.footnote.weight(.semibold))
                            }
                        }
                    } header: { Text(kind == "spending" ? "Monthly budget" : "Set aside per month") }
                }
                Section {
                    let left = notPlanned - (kind == "income" ? -monthly : monthly)
                    Text(left < 0 ? "After adding: \(Money.usd(-left)) over your income" : "After adding: \(Money.usd(left)) of income not planned yet")
                        .font(.footnote).foregroundStyle(left < 0 ? Theme.over : Theme.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd(.new(name: name.trimmingCharacters(in: .whitespaces), kind: kind, monthly: monthly,
                                   goal: kind == "saving" && hasGoal ? goal : nil, starting: starting, goalMonth: goalMonth,
                                   frequency: kind == "income" ? frequency : nil, receivedIn: receivedIn.isEmpty ? nil : receivedIn))
                        dismiss()
                    }
                    .disabled(nameProblem != nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: name) { _, new in
                if kind == "saving", new == "General Savings" { hasGoal = false }
                Task { await loadHint(for: new) }
            }
        }
        .tint(Theme.vib400)
        .interactiveDismissDisabled(!name.isEmpty || monthly > 0)  // a stray swipe shouldn't lose the form
    }

    private var title: String {
        ["income": "Add income", "spending": "Add spending pocket", "saving": "Add savings pocket", "investing": "Add investing pocket"][kind] ?? "Add pocket"
    }

    private var chips: [String] {
        let fromCatalog = catalog.map(\.displayName)
        return (fromCatalog + (Self.suggestions[kind] ?? [])).reduce(into: [String]()) { list, c in
            if !list.contains(c), !taken.contains(c.lowercased()) { list.append(c) }
        }
    }

    private var nameProblem: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return nil }
        if taken.contains(n.lowercased()) { return "There's already a pocket called \(n)." }
        if n.count > 40 { return "Keep the name under 40 characters." }
        return nil
    }

    private var needed: Double? {
        guard goal > 0 else { return nil }
        return max(0, (goal - starting) / Double(monthsUntil(goalMonth)))
    }

    private func loadHint(for name: String) async {
        guard kind == "spending", name.trimmingCharacters(in: .whitespaces).count >= 3 else { hint = nil; return }
        try? await Task.sleep(for: .milliseconds(350))
        guard name == self.name else { return }
        let r: BudgetHint? = try? await api.get("budget/hint", query: ["name": name])
        hint = r?.hint
    }
}

// MARK: - Pop-ups

/// Archiving: where should the pocket's money go?
struct ArchiveSheet: View {
    let pocket: EditPocket
    let others: [EditPocket]
    let onArchive: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(question).font(.system(size: 14))
                } footer: { Text("Archived pockets are kept, never deleted, so past months still show them.") }
                if pocket.kind != "income" {
                    Section("Move it to") {
                        Picker("Move it to", selection: $target) {
                            Text(pocket.kind == "spending" ? "Unsorted (pick later in Review)" : "Unassigned").tag("")
                            ForEach(others) { Text($0.name).tag($0.original?.name ?? $0.name) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Archive \(pocket.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Go back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Archive", role: .destructive) { onArchive(target.isEmpty ? nil : target) }
                }
            }
        }
        .tint(Theme.vib400)
    }

    private var question: String {
        switch pocket.kind {
        case "spending":
            let spent = pocket.original?.spent ?? 0
            return spent > 0 ? "This month's \(Money.usd(spent)) of expenses in \(pocket.name) need a new pocket." : "\(pocket.name) has no expenses this month."
        case "income":
            return "New deposits like these will go to Other income."
        default:
            let saved = pocket.original?.saved ?? 0
            return "\(pocket.name) holds \(Money.usd(saved)). Where should it go?"
        }
    }
}

/// Saving a plan that's over income: are you sure, and which pocket gives up the extra?
struct OverIncomeSheet: View {
    let reply: OverIncomeReply
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your plan is \(Money.usd(reply.over)) over your income. Are you sure?").font(.system(size: 15, weight: .semibold))
                    Text("Where should the extra \(Money.usd(reply.extra)) come from?").font(.system(size: 14)).foregroundStyle(Theme.muted)
                } footer: { Text("The pocket you pick gives up \(Money.usd(reply.extra)) inside the app. No money moves between banks.") }
                Section("Savings and investing pockets") {
                    ForEach(reply.sources) { s in
                        let enough = s.available + 0.005 >= reply.extra
                        Button { onPick(s.name) } label: {
                            HStack {
                                Text(s.displayName).foregroundStyle(enough ? Theme.text : Theme.muted)
                                Spacer()
                                Text(enough ? "\(Money.usd(s.available)) available" : "only \(Money.usd(s.available))")
                                    .monospacedDigit().foregroundStyle(enough ? Theme.muted : Theme.over)
                            }
                        }
                        .disabled(!enough)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Over income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Go back") { dismiss() } } }
        }
        .tint(Theme.vib400)
    }
}
