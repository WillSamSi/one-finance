import PhotosUI
import SwiftUI

/// The + button: a small menu (Scan receipt, Add expense, Add income) plus an "Or type it" box.
struct AddMenuSheet: View {
    var focusQuickType = false
    var onSaved: () -> Void

    @FocusState private var typing: Bool
    @State private var path: [AddRoute] = []
    @State private var typed = ""
    @State private var parsing = false
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Theme.onyx900.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 12) {
                    menuButton("Scan receipt", "doc.viewfinder", "The AI reads it and splits it into pockets") { path.append(.scan) }
                    menuButton("Add expense", "minus.circle", "Cash or a card, into a pocket") { path.append(.expense(nil)) }
                    menuButton("Add income", "plus.circle", "Salary, freelance, a gift, a refund") { path.append(.income) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OR TYPE IT").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(Theme.vib300)
                        HStack(spacing: 8) {
                            TextField("lunch 12.50 Chipotle cash", text: $typed)
                                .focused($typing)
                                .textInputAutocapitalization(.never)
                                .submitLabel(.go)
                                .onSubmit { Task { await parse() } }
                                .padding(12)
                                .background(Theme.onyx800, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
                            Button { Task { await parse() } } label: {
                                Group {
                                    if parsing { ProgressView().tint(.white) } else { Image(systemName: "arrow.right") }
                                }
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Theme.vib500, in: Circle())
                            }
                            .disabled(parsing || typed.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        Text("The AI fills in the form; you check it and tap Save.").font(.caption).foregroundStyle(Theme.muted)
                        if let error { Text(error).font(.caption).foregroundStyle(Theme.over) }
                    }
                    .padding(.top, 8)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .expense(let prefill): AddExpenseView(prefill: prefill, onSaved: onSaved)
                case .income: AddIncomeView(onSaved: onSaved)
                case .scan: ScanReceiptView(onSaved: onSaved)
                }
            }
        }
        .tint(Theme.vib400)
        .presentationDetents(focusQuickType ? [.large] : [.medium, .large])
        .onChange(of: path) { _, now in if !now.isEmpty { typing = false } }
        .task {
            if focusQuickType {
                try? await Task.sleep(for: .milliseconds(400))
                typing = true
            }
        }
    }

    private func menuButton(_ title: String, _ icon: String, _ sub: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.vib300)
                    .frame(width: 40, height: 40).background(Theme.vib500.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private func parse() async {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        parsing = true
        error = nil
        do {
            let r: QuickParseResult = try await api.post("entries/parse", body: ["text": text])
            path.append(.expense(ExpensePrefill(r.entry)))
        } catch {
            self.error = error.localizedDescription
        }
        parsing = false
    }
}

enum AddRoute: Hashable {
    case expense(ExpensePrefill?)
    case income
    case scan
}

struct ExpensePrefill: Hashable {
    var amount: Double?
    var currency: String?
    var pocket: String?
    var paidWith: String?
    var note: String?
    var date: String?

    init(_ e: QuickParseResult.QuickEntry) {
        amount = e.amount; currency = e.currency; pocket = e.pocket; paidWith = e.paidWith; note = e.note; date = e.date
    }
}

// MARK: - Add expense

/// The "Not sure" choice: saved with no pocket (Unsorted); the Accountant suggests one later.
let notSurePocket = "__not_sure__"

struct AddExpenseView: View {
    var prefill: ExpensePrefill?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var note = ""
    @State private var pocket: String?
    @State private var paidWith = "cash_usd"
    @State private var date = Date()
    @State private var maxDate = Date()
    @State private var chips: ChipsResponse?
    @State private var options: [PaidWithOption] = []
    @State private var showMore = false
    @State private var error: String?
    @State private var saving = false
    @State private var loadedPrefill = false
    @FocusState private var amountFocused: Bool

    private let api = APIClient()

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(currency == "IDR" ? "Rp" : "$").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.muted)
                    TextField("0", text: $amount)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .font(.system(size: 40, weight: .bold)).monospacedDigit()
                }
                Picker("Currency", selection: $currency) {
                    Text("USD").tag("USD")
                    Text("IDR").tag("IDR")
                }
                .pickerStyle(.segmented)
                TextField("Where / note (e.g. Chipotle)", text: $note)
            }
            Section("Pocket") {
                PocketChipRow(chips: chipsShown, suggested: chips?.suggested, selected: $pocket, onMore: { showMore = true })
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                if pocket == notSurePocket {
                    Label("Not sure: saved to Unsorted. The Accountant will suggest a pocket in Review.", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(Theme.vib300)
                }
                if let p = pocket, let c = (chips?.all ?? []).first(where: { $0.name == p }), c.wouldGoOver {
                    Label("This would put \(p) over: only \(Money.whole(c.left)) left.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.warn)
                }
            }
            Section {
                Picker("Paid with", selection: $paidWith) {
                    ForEach(options.filter { $0.currency == currency }) { Text($0.label).tag($0.id) }
                }
                DatePicker("Date", selection: $date, in: ...maxDate, displayedComponents: .date)
            } footer: {
                Text(paidWith.hasPrefix("cash") ? "Cash stands on its own."
                     : "Marked \"waiting for bank charge\" and matched when the charge arrives, so it's never counted twice.")
            }
            if let error { Section { Text(error).foregroundStyle(Theme.over) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.onyx900)
        .navigationTitle("Add expense")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving || (Money.parse(amount) ?? 0) <= 0 || pocket == nil)
            }
        }
        .sheet(isPresented: $showMore, onDismiss: { Task { await loadChips() } }) {
            PocketPickerSheet(all: chips?.all ?? [], selected: $pocket)
        }
        .task {
            await setup()
            amountFocused = prefill?.amount == nil
        }
        .task(id: "\(note)|\(amount)|\(currency)") {
            try? await Task.sleep(for: .milliseconds(300))
            await loadChips()
        }
        .onChange(of: currency) {
            if !options.contains(where: { $0.id == paidWith && $0.currency == currency }) {
                paidWith = currency == "IDR" ? "cash_idr" : "cash_usd"
            }
        }
    }

    /// The first chips, plus the chosen pocket (or "Not sure") if it came from More….
    private var chipsShown: [PocketChip] {
        var list = chips?.chips ?? []
        if let p = pocket, !list.contains(where: { $0.name == p }) {
            if p == notSurePocket {
                list.insert(PocketChip(name: notSurePocket, kind: "unsorted", left: 0, wouldGoOver: false), at: 0)
            } else if let c = chips?.all.first(where: { $0.name == p }) {
                list.insert(c, at: 0)
            } else {
                list.insert(PocketChip(name: p, kind: "spending", left: 0, wouldGoOver: false), at: 0)
            }
        }
        return list
    }

    private func setup() async {
        guard !loadedPrefill else { return }
        loadedPrefill = true
        if let h: Health = try? await api.get("health") {
            maxDate = DateParse.localDay(h.appDate)
            date = maxDate
        }
        options = (try? await api.get("paid-with") as PaidWithResponse)?.options ?? []
        if let p = prefill {
            if let a = p.amount { amount = a.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(a)) : String(a) }
            if let c = p.currency, ["USD", "IDR"].contains(c) { currency = c }
            if let n = p.note { note = n }
            if let w = p.paidWith { paidWith = w }
            if let d = p.date { date = min(DateParse.localDay(d), maxDate) }
            pocket = p.pocket
        }
    }

    private func loadChips() async {
        let r: ChipsResponse? = try? await api.get("pockets/chips", query: ["note": note, "amount": amount.isEmpty ? "0" : amount, "currency": currency])
        chips = r
        if pocket == nil { pocket = r?.suggested ?? r?.chips.first?.name }
    }

    private func save() async {
        guard let value = Money.parse(amount), let pocket else { return }
        saving = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        do {
            var body: [String: Any] = [
                "amount": value, "currency": currency, "paid_with": paidWith, "note": note, "date": f.string(from: date),
            ]
            if pocket != notSurePocket { body["pocket"] = pocket }
            let _: EntryResult = try await api.post("entries/expense", body: body)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

/// The pocket chips: the suggestion first (pre-selected), then the most used, then More…
/// Each shows what's left; amber if this amount would push it over.
struct PocketChipRow: View {
    let chips: [PocketChip]
    let suggested: String?
    @Binding var selected: String?
    let onMore: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { c in
                    Button { selected = c.name } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if c.name == suggested { AIRing(size: 10, ring: 2.5) }
                                Text(c.name == notSurePocket ? "Not sure" : c.name).font(.system(size: 13, weight: .semibold))
                            }
                            Text(c.name == notSurePocket ? "Unsorted" : c.wouldGoOver ? "Over · \(Money.whole(c.left)) left" : "\(Money.whole(c.left)) left")
                                .font(.system(size: 11)).monospacedDigit()
                        }
                        .foregroundStyle(c.wouldGoOver ? Theme.warn : (selected == c.name ? Theme.vib100 : Theme.text))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(selected == c.name ? Theme.vib500.opacity(0.3) : Theme.onyx700, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(c.wouldGoOver ? Theme.warn.opacity(0.7) : (selected == c.name ? Theme.vib400 : Theme.hairline), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                Button(action: onMore) {
                    Text("More…").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.vib300)
                        .padding(.horizontal, 14).padding(.vertical, 15)
                        .background(Theme.onyx700, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Every pocket, grouped, with a search box and what's left.
struct PocketPickerSheet: View {
    let all: [PocketChip]
    @Binding var selected: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showNew = false

    var body: some View {
        NavigationStack {
            List {
                ForEach([("Spending", "spending"), ("Savings", "saving"), ("Investing", "investing")], id: \.1) { title, kind in
                    let rows = all.filter { $0.kind == kind && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                    if !rows.isEmpty {
                        Section(title) {
                            ForEach(rows) { c in
                                Button { selected = c.name; dismiss() } label: {
                                    HStack {
                                        GlowDot(color: Theme.category(c.name), size: 8)
                                        Text(c.name).foregroundStyle(Theme.text)
                                        Spacer()
                                        Text("\(Money.whole(c.left)) \(kind == "spending" ? "left" : "saved")")
                                            .monospacedDigit().foregroundStyle(c.wouldGoOver ? Theme.warn : Theme.muted)
                                        if selected == c.name { Image(systemName: "checkmark").foregroundStyle(Theme.vib400) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Button { showNew = true } label: {
                        Label("New pocket", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { selected = notSurePocket; dismiss() } label: {
                        Label("Not sure", systemImage: "questionmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(Theme.onyx900)
            }
            .sheet(isPresented: $showNew) {
                NewPocketSheet { name in selected = name; dismiss() }
            }
            .searchable(text: $search, prompt: "Search pockets")
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Pick a pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .tint(Theme.vib400)
    }
}


/// + New pocket: made on the spot and used for this expense right away.
struct NewPocketSheet: View {
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "spending"
    @State private var amount = ""
    @State private var hasGoal = false
    @State private var goal = ""
    @State private var goalDate = Date()
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Coffee, Holiday)", text: $name)
                    Picker("Kind", selection: $kind) {
                        Text("Spending").tag("spending")
                        Text("Savings").tag("saving")
                        Text("Investing").tag("investing")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text(kind == "spending" ? "Monthly budget" : "Set aside per month")
                        Spacer()
                        Text("$").foregroundStyle(Theme.muted)
                        TextField("0", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                }
                if kind == "saving" {
                    Section {
                        Toggle("Goal", isOn: $hasGoal)
                        if hasGoal {
                            HStack {
                                Text("Goal amount")
                                Spacer()
                                Text("$").foregroundStyle(Theme.muted)
                                TextField("0", text: $goal).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                            }
                            DatePicker("By", selection: $goalDate, displayedComponents: .date)
                        }
                    } footer: { Text("A goal amount and date are optional.") }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.over) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("New pocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }.disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .tint(Theme.vib400)
    }

    private func create() async {
        saving = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        var body: [String: Any] = ["name": name, "kind": kind, "monthly_budget": Money.parse(amount) ?? 0]
        if kind == "saving", hasGoal, let g = Money.parse(goal) {
            body["goal_amount"] = g
            body["goal_date"] = f.string(from: goalDate)
        }
        do {
            struct Created: Decodable { let ok: Bool; let name: String }
            let r: Created = try await APIClient().post("pockets", body: body)
            onCreated(r.name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
