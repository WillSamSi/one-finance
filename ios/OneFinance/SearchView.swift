import SwiftUI

/// Search: any charge, by merchant, pocket, receipt item or Amazon product.
struct SearchView: View {
    @State private var query = ""
    @State private var results: [Txn] = []

    private let api = APIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(title: "Search")
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Merchant, pocket, item…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(Theme.onyx800, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline, lineWidth: 1))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.merchantName ?? t.description).foregroundStyle(Theme.text).lineLimit(1)
                                Text("\(DateParse.shortDay(t.date)) · \(t.pocket ?? "Not recorded yet") · ····\(t.mask ?? "")")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Text(Money.usd(-t.amount)).monospacedDigit()
                                .foregroundStyle(t.amount < 0 ? Theme.positive : Theme.text)
                        }
                        .padding(.vertical, 10)
                        Divider().overlay(Theme.hairline)
                    }
                }
                .padding(.bottom, 180)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))  // wait for typing to pause
            if let r: TransactionList = try? await api.get("transactions", query: ["q": query, "limit": "100"]) {
                results = r.transactions
            }
        }
    }
}
