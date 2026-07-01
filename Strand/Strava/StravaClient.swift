import Foundation

/// Stateless Strava REST calls (OAuth token exchange/refresh + activity upload + status poll). Async/await
/// over `URLSession`, matching the AI Coach providers' style. No stored state — the caller (`StravaService`)
/// owns credentials and decides when to refresh. All endpoints are HTTPS (allowed by the app's ATS).
enum StravaClient {

    static let tokenURL  = URL(string: "https://www.strava.com/oauth/token")!
    static let uploadURL = URL(string: "https://www.strava.com/api/v3/uploads")!
    /// OAuth scopes: read the athlete + write activities (upload). `activity:write` is what /uploads needs.
    static let scope = "read,activity:write"

    struct Tokens: Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: TimeInterval
    }

    enum StravaError: LocalizedError {
        case http(Int, String)
        case badResponse
        case uploadRejected(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "Strava HTTP \(code): \(body)"
            case .badResponse: return "Unexpected Strava response."
            case .uploadRejected(let msg): return "Strava rejected the upload: \(msg)"
            }
        }
    }

    // MARK: OAuth

    /// Exchange an authorization `code` (from the consent redirect) for tokens.
    static func exchange(clientId: String, clientSecret: String, code: String,
                         session: URLSession = .shared) async throws -> Tokens {
        try await token(form: [
            "client_id": clientId, "client_secret": clientSecret,
            "code": code, "grant_type": "authorization_code",
        ], session: session)
    }

    /// Trade a refresh token for a fresh access token (Strava rotates the refresh token too).
    static func refresh(clientId: String, clientSecret: String, refreshToken: String,
                        session: URLSession = .shared) async throws -> Tokens {
        try await token(form: [
            "client_id": clientId, "client_secret": clientSecret,
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ], session: session)
    }

    private static func token(form: [String: String], session: URLSession) async throws -> Tokens {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(form).data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let expires = obj["expires_at"] as? TimeInterval else { throw StravaError.badResponse }
        return Tokens(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    // MARK: Upload

    /// Upload a TCX document. Returns Strava's upload id (poll `uploadStatus` for the activity id).
    static func upload(tcx: Data, name: String, externalId: String, accessToken: String,
                       session: URLSession = .shared) async throws -> Int {
        let boundary = "noop-\(externalId)-boundary"
        var body = Data()
        func field(_ nameField: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(nameField)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("name", name)
        field("data_type", "tcx")
        field("external_id", externalId)
        // The file part (the sport is carried inside the TCX itself).
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(externalId).tcx\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/xml\r\n\r\n".data(using: .utf8)!)
        body.append(tcx)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StravaError.badResponse
        }
        if let err = obj["error"] as? String, !err.isEmpty { throw StravaError.uploadRejected(err) }
        guard let id = obj["id"] as? Int else { throw StravaError.badResponse }
        return id
    }

    /// Poll an upload. `done` is true once Strava finished processing (success → activityId set, or the
    /// `error` string explains a rejection). While still processing, `done` is false.
    static func uploadStatus(id: Int, accessToken: String,
                             session: URLSession = .shared) async throws -> (done: Bool, activityId: Int?, error: String?) {
        var req = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(id)")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try check(resp, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StravaError.badResponse
        }
        let error = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let activityId = obj["activity_id"] as? Int
        return (done: error != nil || activityId != nil, activityId: activityId, error: error)
    }

    // MARK: Helpers

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw StravaError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw StravaError.http(http.statusCode, body)
        }
    }

    /// Build the Strava authorization URL the consent web session opens.
    static func authorizeURL(clientId: String, redirectURI: String) -> URL {
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: scope),
        ]
        return c.url!
    }

    static func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }
}
