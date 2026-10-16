import Foundation

enum FetchResult<Value: Sendable>: Sendable {
    case ok(Value)
    case auth(Int)
    case transient(String)
}

/// GET requests with no cookies and no cache.
struct HTTPClient: Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func get(_ url: URL, headers: [String: String]) async -> FetchResult<Data> {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .ok(data)
            case 401, 403: return .auth(status)
            default: return .transient("HTTP \(status)")
            }
        } catch {
            return .transient(error.localizedDescription)
        }
    }
}
