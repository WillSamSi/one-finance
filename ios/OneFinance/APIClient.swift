import Foundation

/// Talks to the One Finance backend. The app never holds Plaid, SnapTrade or Portkey keys.
struct APIClient {
    /// The Simulator reaches the Mac's localhost directly.
    static var baseURL = URL(string: "http://localhost:8000")!

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: Self.baseURL.appending(path: path))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct Health: Decodable {
    let ok: Bool
    let appDate: String
    let dataMode: String
    let plaidKeys: Bool
}

struct AccountsResponse: Decodable {
    let accounts: [Account]
    let totalAssetsUsd: Double
}

struct Account: Decodable, Identifiable {
    let id: String
    let institution: String
    let name: String
    let type: String
    let subtype: String?
    let mask: String?
    let currency: String
    let currentBalance: Double
    let asOf: String?
    let balanceUsd: Double
}
