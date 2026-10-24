import SwiftUI

/// The + button: an expense typed in by hand (e.g. cash). The Accountant later looks for a
/// receipt or bank charge that matches it.
struct AddExpenseSheet: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var description = ""
    @State private var pocket = "Food"
    @State private var date = Date()
    @State private var pockets: [String] = []
    @State private var error: String?
    @State private var saving = false

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $amount).keyboardType(.decimalPad).font(.system(size: 28, weight: .bold))
                    TextField("What was it?", text: $description)
                    Picker("Pocket", selection: $pocket) {
                        ForEach(pockets, id: \.self) { Text($0) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.over) } }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.onyx900)
            .navigationTitle("Add expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving || Double(amount) == nil || description.isEmpty)
                }
            }
        }
        .tint(Theme.vib400)
        .task {
            if let list: PocketList = try? await api.get("pockets") {
                pockets = list.pockets.filter { $0.kind != "investing" }.map(\.name)  // spending + savings pockets
            }
        }
    }

    private func save() async {
        guard let value = Double(amount) else { return }
        saving = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        do {
            let _: OK = try await api.post("entries/manual", body: [
                "date": f.string(from: date), "description": description, "amount": value, "pocket": pocket,
            ])
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}
