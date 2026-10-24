import SwiftUI

/// Budget setup: edit each pocket's monthly amount and goal, rename custom pockets,
/// add pockets from the catalog, and ask the AI to suggest amounts from past spending.
struct BudgetSetupSheet: View {
    var suggestOnOpen = false

    @Environment(\.dismiss) private var dismiss
    @State private var pockets: [PocketList.PocketInfo] = []
    @State private var catalog: [PocketList.PocketInfo] = []
    @State private var amounts: [String: String] = [:]
    @State private var goals: [String: String] = [:]
    @State private var names: [String: String] = [:]
    @State private var suggestions: [String: BudgetSuggestionResult.Item] = [:]
    @State private var suggestionNote: String?
    @State private var suggesting = false
    @State private var steps: [AgentEvent] = []
    @State private var error: String?
    @State private var saving = false

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { Task { await suggest() } } label: {
                        HStack(spacing: 8) {
                            AIRing(size: 16, ring: 4)
                            Text(suggesting ? "The Advisor is looking at your spending…" : "AI suggest amounts")
                        }
                    }
                    .disabled(suggesting)
                    if suggesting { AgentActivity(steps: steps).listRowBackground(Color.clear) }
                    if let suggestionNote { Text(suggestionNote).font(.footnote).foregroundStyle(Theme.muted) }
                }
                Section("Spending, per month") {
                    ForEach(pockets.filter { $0.kind == "spending" }) { row($0) }
                }
                Section("Savings and investing, set aside per month") {
                    ForEach(pockets.filter { $0.kind != "spending" }) { row($0, showGoal: $0.kind == "saving") }
                }
                if !catalog.isEmpty {
                    Section("Add a pocket") {
                        ForEach(catalog) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name)
                                    if let d = p.description { Text(d).font(.caption).foregroundStyle(Theme.muted) }
                                }
                                Spacer()
                                Button("Add") { Task { await add(p) } }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.over) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Budget setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } }.disabled(saving) }
            }
        }
        .tint(Theme.vib400)
        .task {
            await load()
            if suggestOnOpen { await suggest() }
        }
    }

    private func row(_ p: PocketList.PocketInfo, showGoal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if p.custom == 1 {
                    TextField("Name", text: binding(for: $names, p.name, default: p.name)).font(.body.weight(.medium))
                } else {
                    Text(p.name).font(.body.weight(.medium))
                }
                Spacer()
                Text("$").foregroundStyle(Theme.muted)
                TextField("0", text: binding(for: $amounts, p.name, default: format(p.monthlyBudget)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80).monospacedDigit()
            }
            if showGoal {
                HStack {
                    Text("Goal (optional)").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    TextField("none", text: binding(for: $goals, p.name, default: format(p.goalAmount)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100).font(.caption).monospacedDigit()
                }
            }
            if let s = suggestions[p.name] {
                HStack(alignment: .top) {
                    Text("AI: \(Money.whole(s.monthlyAmount)) · \(s.reason)").font(.caption).foregroundStyle(Theme.vib300)
                    Spacer()
                    Button("Use") { amounts[p.name] = format(s.monthlyAmount) }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
                }
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) { Task { await remove(p) } }
        }
    }

    private func binding(for dict: Binding<[String: String]>, _ key: String, default value: String) -> Binding<String> {
        Binding(get: { dict.wrappedValue[key] ?? value }, set: { dict.wrappedValue[key] = $0 })
    }

    private func format(_ v: Double?) -> String {
        guard let v else { return "" }
        return v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }

    private func load() async {
        guard let list: PocketList = try? await api.get("pockets") else { return }
        pockets = list.pockets
        catalog = list.catalog
    }

    private func save() async {
        saving = true
        error = nil
        for p in pockets {
            var body: [String: Any] = [:]
            if let a = amounts[p.name], let v = Double(a), v != p.monthlyBudget { body["monthly_budget"] = v }
            if let g = goals[p.name], Double(g) != p.goalAmount { body["goal_amount"] = Double(g) ?? 0 }
            if let n = names[p.name], !n.isEmpty, n != p.name { body["new_name"] = n }
            if body.isEmpty { continue }
            do {
                let _: OK = try await patch(p.name, body)
            } catch {
                self.error = "\(p.name): \(error.localizedDescription)"
                saving = false
                return
            }
        }
        saving = false
        dismiss()
    }

    private func add(_ p: PocketList.PocketInfo) async {
        let _: OK? = try? await patch(p.name, ["active": true])
        await load()
    }

    private func remove(_ p: PocketList.PocketInfo) async {
        let _: OK? = try? await patch(p.name, ["active": false])
        await load()
    }

    private func patch(_ name: String, _ body: [String: Any]) async throws -> OK {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var request = URLRequest(url: URL(string: "\(APIClient.baseURL.absoluteString)/pockets/\(encoded)")!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(message: detail ?? "Couldn't save.")
        }
        return OK(ok: true)
    }

    private func suggest() async {
        suggesting = true
        steps = []
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            let r: BudgetSuggestionResult = try await api.post("agents/suggest-budget")
            if let s = r.suggestion {
                suggestions = Dictionary(uniqueKeysWithValues: s.suggestions.map { ($0.pocket, $0) })
                suggestionNote = s.note
            }
        } catch {
            self.error = error.localizedDescription
        }
        watcher.cancel()
        suggesting = false
    }
}
