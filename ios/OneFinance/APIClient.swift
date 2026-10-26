import Foundation

/// Talks to the One Finance backend. The app never holds Plaid, SnapTrade or Portkey keys.
struct APIClient {
    /// Where the backend runs. The Simulator reaches the Mac's localhost directly; on an iPhone,
    /// enter the Mac's address once (e.g. http://My-Mac.local:8000) on the "Can't reach the
    /// backend" card or in More → Help and about → Backend address. Saved on the phone.
    static let addressKey = "backendURL"
    static var baseURL: URL {
        if let saved = UserDefaults.standard.string(forKey: addressKey), let url = URL(string: saved), url.host != nil {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }

    /// "my-mac.local:8000", "http://192.168.1.20:8000" → a URL with http:// and the port.
    static func normalized(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard var c = URLComponents(string: t), c.host != nil else { return nil }
        if c.port == nil { c.port = 8000 }
        c.path = ""
        return c.url
    }

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

    func patch<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type = T.self) async throws -> T {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: 60)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try decode(data, response)
    }

    /// POST that hands back the status code and body as they are (for answers like 409 "over income").
    func send(_ path: String, body: [String: Any]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: Self.baseURL.appending(path: path), timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func decodeBody<T: Decodable>(_ data: Data, as type: T.Type = T.self) throws -> T {
        try decoder.decode(T.self, from: data)
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
