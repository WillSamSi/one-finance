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

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        return try decode(data, response)
    }

    /// Agent runs can take a few minutes, so POSTs wait up to 10 minutes.
    func post<T: Decodable>(_ path: String, body: [String: Any]? = nil, as type: T.Type = T.self) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data, response)
    }

    private func decode<T: Decodable>(_ data: Data, _ response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw APIError(message: detail ?? "The server answered \(http.statusCode).")
        }
        return try decoder.decode(T.self, from: data)
    }
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct OK: Decodable { let ok: Bool }

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
