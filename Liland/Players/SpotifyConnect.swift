import AppKit
import CryptoKit
import Network
import Security

final class SpotifyConnect {
    struct Device: Equatable {
        let id: String
        let name: String
        let type: String
        let isActive: Bool
        let isRestricted: Bool
    }

    enum Failure: Error, Equatable {
        case signedOut
        case notAllowed
        case rejected
        case unreachable
    }

    static let shared = SpotifyConnect()

    private static let clientID = "8898128039864d769fb0543aac5b8bba"
    private static let port: UInt16 = 43819
    private static let redirectURI = "http://127.0.0.1:43819/callback"
    private static let scopes = "user-read-playback-state user-modify-playback-state"
    private static let loginTimeout: TimeInterval = 300

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshWaiters: [(Result<String, Failure>) -> Void] = []
    private var listener: NWListener?
    private var login: (verifier: String, state: String, completion: (Bool) -> Void)?
    private var loginTimeoutWork: DispatchWorkItem?

    var isSignedIn: Bool { TokenStore.read() != nil }
    var isSigningIn: Bool { login != nil }

    // MARK: - Signing in

    func signIn(completion: @escaping (Bool) -> Void) {
        if let login {
            self.login = (login.verifier, login.state, completion)
            openAuthorization(verifier: login.verifier, state: login.state)
            return
        }
        guard startListener() else { return completion(false) }
        let verifier = Self.randomString(bytes: 64)
        let state = Self.randomString(bytes: 16)
        login = (verifier, state, completion)
        let timeout = DispatchWorkItem { [weak self] in self?.finishLogin(success: false) }
        loginTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.loginTimeout, execute: timeout)
        openAuthorization(verifier: verifier, state: state)
    }

    private func openAuthorization(verifier: String, state: String) {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private func finishLogin(success: Bool) {
        loginTimeoutWork?.cancel()
        loginTimeoutWork = nil
        listener?.cancel()
        listener = nil
        let completion = login?.completion
        login = nil
        completion?(success)
    }

    private func startListener() -> Bool {
        if listener != nil { return true }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: parameters, on: port)
        else { return false }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            NSLog("Liland: Spotify sign-in listener failed: \(error)")
            self?.finishLogin(success: false)
        }
        listener.start(queue: .main)
        self.listener = listener
        return true
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            guard let self, parts.count > 1,
                  let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == "/callback",
                  let login = self.login
            else {
                Self.respond(connection, status: "404 Not Found", text: "")
                return
            }
            let items = url.queryItems ?? []
            func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
            let failed = String(localized: "Couldn't sign in. Try again from Liland.")
            guard value("state") == login.state else {
                Self.respond(connection, status: "400 Bad Request", text: failed)
                return
            }
            guard let code = value("code") else {
                Self.respond(connection, status: "200 OK", text: failed)
                self.finishLogin(success: false)
                return
            }
            self.requestToken(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI, "code_verifier": login.verifier]) { result in
                let success = (try? result.get()) != nil
                Self.respond(connection, status: "200 OK", text: success ? String(localized: "Signed in. You can close this tab and go back to Liland.") : failed)
                self.finishLogin(success: success)
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, text: String) {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = "<!doctype html><meta charset=utf-8><title>Liland</title><body style=\"font:17px -apple-system,sans-serif;text-align:center;padding-top:96px;background:#111;color:#eee\">\(escaped)</body>"
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Tokens

    private func requestToken(_ form: [String: String], completion: @escaping (Result<String, Failure>) -> Void) {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return completion(.failure(.unreachable)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded(form.merging(["client_id": Self.clientID]) { $1 })
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard status == 200, let json, let token = json["access_token"] as? String else {
                    completion(.failure(status == 400 || status == 401 ? .signedOut : .unreachable))
                    return
                }
                if let refresh = json["refresh_token"] as? String { TokenStore.save(refresh) }
                self.accessToken = token
                self.accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
                completion(.success(token))
            }
        }.resume()
    }

    private func withToken(_ completion: @escaping (Result<String, Failure>) -> Void) {
        if let accessToken, Date() < accessExpiry { return completion(.success(accessToken)) }
        guard let refresh = TokenStore.read() else { return completion(.failure(.signedOut)) }
        refreshWaiters.append(completion)
        guard refreshWaiters.count == 1 else { return }
        requestToken(["grant_type": "refresh_token", "refresh_token": refresh]) { [weak self] result in
            guard let self else { return }
            if result == .failure(.signedOut) { TokenStore.delete() }
            let waiters = self.refreshWaiters
            self.refreshWaiters = []
            waiters.forEach { $0(result) }
        }
    }

    // MARK: - Web API

    func devices(completion: @escaping (Result<[Device], Failure>) -> Void) {
        call("GET", "/me/player/devices") { result in
            completion(result.map { data in
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let list = json?["devices"] as? [[String: Any]] ?? []
                return list.compactMap { item in
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                    return Device(
                        id: id,
                        name: name,
                        type: item["type"] as? String ?? "",
                        isActive: item["is_active"] as? Bool ?? false,
                        isRestricted: item["is_restricted"] as? Bool ?? false
                    )
                }
            })
        }
    }

    func transfer(to deviceID: String, completion: @escaping (Result<Void, Failure>) -> Void) {
        call("PUT", "/me/player", body: ["device_ids": [deviceID]]) { completion($0.map { _ in () }) }
    }

    private func call(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        retried: Bool = false,
        completion: @escaping (Result<Data, Failure>) -> Void
    ) {
        withToken { [weak self] result in
            guard let self else { return }
            let token: String
            switch result {
            case .failure(let failure): return completion(.failure(failure))
            case .success(let value): token = value
            }
            guard let url = URL(string: "https://api.spotify.com/v1" + path) else { return completion(.failure(.unreachable)) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    switch status {
                    case 200..<300:
                        completion(.success(data ?? Data()))
                    case 401 where !retried:
                        self.accessToken = nil
                        self.call(method, path, body: body, retried: true, completion: completion)
                    case 401:
                        completion(.failure(.signedOut))
                    case 403:
                        let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        completion(.failure(message.localizedCaseInsensitiveContains("registered") ? .notAllowed : .rejected))
                    case 0:
                        completion(.failure(.unreachable))
                    default:
                        completion(.failure(.rejected))
                    }
                }
            }.resume()
        }
    }

    // MARK: - Helpers

    private static func randomString(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ form: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

private enum TokenStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "Liland") + ".spotify"
    private static let account = "refresh_token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
