import Foundation

actor UniFiAPI {
    private var baseURL: String = ""
    private var apiKey: String = ""
    private var siteID: String = ""
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(
            configuration: config,
            delegate: SelfSignedCertDelegate.shared,
            delegateQueue: nil
        )
    }

    func configure(host: String, apiKey: String, siteID: String) {
        self.baseURL = host
        self.apiKey = apiKey
        self.siteID = siteID
    }

    private func apiURL(_ path: String) -> URL? {
        URL(string: "\(baseURL)/proxy/network/integration/v1/sites/\(siteID)\(path)")
    }

    private func request(_ path: String) throws -> URLRequest {
        guard let url = apiURL(path) else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    func fetchDevices() async throws -> [UniFiDevice] {
        let req = try request("/devices?limit=200")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(UniFiDeviceResponse.self, from: data).data
    }

    func fetchStats(deviceID: String) async throws -> DeviceStats {
        let req = try request("/devices/\(deviceID)/statistics/latest")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(DeviceStats.self, from: data)
    }

    func rebootDevice(id: String) async throws -> (ok: Bool, status: Int) {
        var req = try request("/devices/\(id)/actions")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["action": "RESTART"])
        let (_, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status == 200, status)
    }

    enum APIError: LocalizedError {
        case invalidURL
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Invalid API URL"
            case .badResponse(let code): "API returned HTTP \(code)"
            }
        }
    }
}

// Accept self-signed certificates (UniFi controllers use self-signed TLS)
final class SelfSignedCertDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = SelfSignedCertDelegate()

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
