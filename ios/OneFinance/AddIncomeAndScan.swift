import PhotosUI
import SwiftUI

// MARK: - Add income

struct AddIncomeView: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var currency = "USD"
    @State private var source = "salary"
    @State private var receivedIn = "cash_usd"
    @State private var note = ""
    @State private var date = Date()
    @State private var maxDate = Date()
    @State private var options: [PaidWithOption] = []
    @State private var savingsPockets: [PocketList.PocketInfo] = []
    @State private var assign: [String: String] = [:]
    @State private var error: String?
    @State private var saving = false

    private let api = APIClient()
    private let sources = ["salary", "freelance", "gift", "refund", "other"]

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(currency == "IDR" ? "Rp" : "$").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.muted)
                    TextField("0", text: $amount).keyboardType(.decimalPad).font(.system(size: 40, weight: .bold)).monospacedDigit()
                }
                Picker("Currency", selection: $currency) {
                    Text("USD").tag("USD")
                    Text("IDR").tag("IDR")
                }
                .pickerStyle(.segmented)
                Picker("Source", selection: $source) {
                    ForEach(sources, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Received in", selection: $receivedIn) {
                    ForEach(options.filter { $0.currency == currency }) { Text($0.label).tag($0.id) }
                }
                DatePicker("Date", selection: $date, in: ...maxDate, displayedComponents: .date)
                TextField("Note (optional)", text: $note)
            } footer: {
                Text(receivedIn.hasPrefix("cash") ? "Cash stands on its own."
                     : "Matched to the bank deposit when it arrives, so it isn't counted twice.")
            }
            Section {
                ForEach(savingsPockets) { p in
                    HStack {
                        GlowDot(color: Theme.category(p.name), size: 8)
                        Text(p.name)
                        Spacer()
                        Text("$").foregroundStyle(Theme.muted)
                        TextField("0", text: Binding(get: { assign[p.name] ?? "" }, set: { assign[p.name] = $0 }))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80).monospacedDigit()
                    }
                }
                Button("Use my monthly savings amounts") {
                    for p in savingsPockets { if let m = p.monthlyBudget { assign[p.name] = String(Int(m)) } }
                }
            } header: {
                Text("Assign to pockets (optional)")
            } footer: {
                Text("Anything not assigned goes to Unassigned.")
            }
            if let error { Section { Text(error).foregroundStyle(Theme.over) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.onyx900)
        .navigationTitle("Add income")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving || (Money.parse(amount) ?? 0) <= 0)
            }
        }
        .task {
            if let h: Health = try? await api.get("health") { maxDate = DateParse.localDay(h.appDate); date = maxDate }
            options = (try? await api.get("paid-with") as PaidWithResponse)?.options ?? []
            savingsPockets = (try? await api.get("pockets") as PocketList)?.pockets.filter { $0.kind != "spending" } ?? []
        }
        .onChange(of: currency) {
            if !options.contains(where: { $0.id == receivedIn && $0.currency == currency }) {
                receivedIn = currency == "IDR" ? "cash_idr" : "cash_usd"
            }
        }
    }

    private func save() async {
        guard let value = Money.parse(amount) else { return }
        saving = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let lines = assign.compactMap { name, v -> [String: Any]? in
            guard let a = Money.parse(v), a > 0 else { return nil }
            return ["pocket": name, "amount": a]
        }
        do {
            let _: EntryResult = try await api.post("entries/income", body: [
                "amount": value, "currency": currency, "source": source, "received_in": receivedIn,
                "date": f.string(from: date), "note": note, "assign": lines,
            ])
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

// MARK: - Scan receipt

struct ScanReceiptView: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var showCamera = false
    @State private var result: ScanResult?
    @State private var receiptDate = Date()  // from the photo; editable, and required when unreadable
    @State private var maxDate = Date()      // the app's "today"
    @State private var pockets: [String] = []        // one per item
    @State private var useMatch = true
    @State private var paidWith = "cash_usd"
    @State private var options: [PaidWithOption] = []
    @State private var steps: [AgentEvent] = []
    @State private var reading = false
    @State private var saving = false
    @State private var error: String?

    private let api = APIClient()

    var body: some View {
        Form {
            if result == nil {
                Section {
                    if reading {
                        Label("Reading the receipt…", systemImage: "doc.text.viewfinder")
                    } else {
                        if CameraPicker.isAvailable {
                            Button { showCamera = true } label: { Label("Take a photo", systemImage: "camera") }
                        }
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Choose a receipt photo", systemImage: "photo.on.rectangle")
                        }
                    }
                    if reading { AgentActivity(steps: steps).listRowBackground(Color.clear) }
                } footer: {
                    Text("The Accountant reads the store, date, items, tax and total, and suggests a pocket for each item. Nothing is saved until you confirm.")
                }
            }
            if let r = result {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.receipt.store).font(.headline)
                        Text("\(Money.usd(r.receipt.total))\(r.receipt.cardLast4.map { " · card ••\($0)" } ?? "")")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    DatePicker("Date", selection: $receiptDate, in: ...maxDate, displayedComponents: .date)
                } footer: {
                    if r.receipt.date.isEmpty { Text("The date on the photo couldn't be read. Check it before you confirm.") }
                }
                Section("Checks") {
                    ForEach(r.checks) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.ok ? Theme.positive : Theme.warn)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name).font(.subheadline.weight(.semibold))
                                Text(c.detail).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if let m = r.bankMatch {
                        Toggle(isOn: $useMatch) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Matches ••\(m.accountLast4 ?? "") · \(DateParse.shortDay(m.date)) · \(Money.usd(m.amount)) ✓")
                                    .font(.subheadline.weight(.semibold))
                                Text(m.description).font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    } else {
                        Label("No matching charge yet; will check when it arrives.", systemImage: "clock")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
                Section("Items and pockets") {
                    ForEach(Array(r.receipt.items.enumerated()), id: \.offset) { i, item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.subheadline).lineLimit(1)
                                Text(Money.usd(item.price)).font(.caption).monospacedDigit().foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Menu {
                                ForEach(r.pockets, id: \.self) { p in Button(p) { pockets[i] = p } }
                            } label: {
                                HStack(spacing: 4) {
                                    GlowDot(color: Theme.category(pockets[safe: i] ?? ""), size: 6)
                                    Text(pockets[safe: i] ?? "Pick").font(.caption.weight(.semibold))
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Theme.onyx700, in: Capsule())
                            }
                        }
                    }
                    let split = Dictionary(grouping: zip(pockets, r.receipt.items).map { ($0, $1.price) }, by: { $0.0 })
                        .mapValues { $0.reduce(0) { $0 + $1.1 } }
                    if split.count > 1 {
                        Text("Split: " + split.sorted { $0.value > $1.value }.map { "\($0.key) \(Money.usd($0.value))" }.joined(separator: " · ")
                             + " (plus tax, shared)")
                            .font(.caption).foregroundStyle(Theme.vib300)
                    }
                }
                if r.bankMatch == nil || !useMatch {
                    Section {
                        Picker("Paid with", selection: $paidWith) {
                            ForEach(options.filter { $0.currency == "USD" }) { Text($0.label).tag($0.id) }
                        }
                    }
                }
                Section {
                    Text("Read with \(r.inputTokens + r.outputTokens) tokens").font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            if let error { Section { Text(error).foregroundStyle(Theme.over) } }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.onyx900)
        .navigationTitle("Scan receipt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if result != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") { Task { await confirm() } }.disabled(saving || pockets.contains(""))
                }
            }
        }
        .task { options = (try? await api.get("paid-with") as PaidWithResponse)?.options ?? [] }
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                guard let data = try? await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    error = "Couldn't load that photo."
                    return
                }
                await read(image)
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await read(image) } }.ignoresSafeArea()
        }
    }

    private func read(_ picture: UIImage) async {
        reading = true
        error = nil
        steps = []
        let watcher = Task { await AgentWatcher.watch(api: api) { steps.append(contentsOf: $0) } }
        do {
            guard let image = picture.scaled(maxSide: 2000).jpegData(compressionQuality: 0.8) else {
                throw APIError(message: "Couldn't read that photo.")
            }
            let r: ScanResult = try await api.post("receipts/scan", body: [
                "image_base64": image.base64EncodedString(), "media_type": "image/jpeg",
            ])
            if let h: Health = try? await api.get("health") { maxDate = DateParse.localDay(h.appDate) }
            receiptDate = r.receipt.date.isEmpty ? maxDate : min(DateParse.localDay(r.receipt.date), maxDate)
            pockets = r.receipt.items.map { $0.suggestedPocket.flatMap { r.pockets.contains($0) ? $0 : nil } ?? r.pockets.first ?? "" }
            result = r
        } catch {
            self.error = error.localizedDescription
        }
        watcher.cancel()
        reading = false
    }

    private func confirm() async {
        guard let r = result else { return }
        saving = true
        var body: [String: Any] = [
            "items": zip(r.receipt.items, pockets).map { ["name": $0.name, "price": $0.price, "pocket": $1] },
            "paid_with": paidWith,
            "date": DateParse.isoDay(receiptDate),
        ]
        if let m = r.bankMatch, useMatch {
            body["transaction_id"] = m.transactionId
            if let acct = options.first(where: { $0.label.hasSuffix("••\(m.accountLast4 ?? "-")") }) { body["paid_with"] = acct.id }
        }
        do {
            let _: EntryResult = try await api.post("receipts/\(r.receiptId)/confirm", body: body)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        saving = false
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Camera

/// The camera for "Take a photo" (PhotosPicker only reads the library).
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPicked(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

extension UIImage {
    /// A 12-megapixel camera photo is ~4000 px; 2000 px still reads every line of a receipt
    /// and sends a quarter of the pixels to the model.
    func scaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale), format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))) }
    }
}
