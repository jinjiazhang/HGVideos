import Foundation

/// Protocol reference: HGhubX api.rs::api_play and net.rs::edge.
/// No account token, ad endpoint, entitlement mutation or purchase call is used.
actor HGService {
    static let shared = HGService()
    private let session: URLSession
    private var origin: URL?
    private var resolving: Task<URL, Error>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0", "Accept": "application/json"]
        session = URLSession(configuration: config)
        if let saved = defaults.string(forKey: "verifiedOrigin"), let value = URL(string: saved),
           value.scheme == "https", value.path.isEmpty || value.path == "/" { origin = value }
    }

    func resetConnection() { origin = nil; resolving?.cancel(); resolving = nil; defaults.removeObject(forKey: "verifiedOrigin") }
    func currentHost() -> String { origin?.host ?? "自动选择" }

    func list(page: Int, kind: FeedKind, query: String = "") async throws -> DramaPage {
        let path: String
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path = "/api/videos?page=\(page)&size=24" + (kind == .original ? "&is_original=1" : "")
        } else {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "type", value: "video"),
                                     URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "size", value: "24")]
            path = "/api/search?" + (components.percentEncodedQuery ?? "")
        }
        return DramaPage(json: try await request(method: "GET", path: path))
    }

    func detail(id: Int) async throws -> DramaDetail {
        try DramaDetail(json: await request(method: "GET", path: "/api/videos/\(id)"))
    }

    func playback(id: Int, episode: Int) async throws -> PlaybackSource {
        do {
            let value = try await request(method: "POST", path: "/api/videos/\(id)/episodes/\(episode)/playback", body: [:])
            if let source = PlaybackSource.parse(value) { return source }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation() }
        let legacy = try await request(method: "GET", path: "/api/videos/\(id)/play?ep=\(episode)&page_texts=0")
        guard let source = PlaybackSource.parse(legacy) else { throw ServiceError.noStream }
        return source
    }

    private func request(method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        for attempt in 0..<2 {
            do {
                let base = try await resolveOrigin()
                let response = try await edge(base: base, method: method, path: path, body: body)
                guard Payload.int(response["status"]) == 1 else { throw ServiceError.business(Payload.string(response["msg"])) }
                guard let data = response["data"] as? [String: Any] else { throw ServiceError.invalidResponse }
                return data
            } catch is CancellationError { throw CancellationError() }
            catch let error as ServiceError {
                if case .business = error { throw error }
                if attempt == 1 { throw error }
                resetConnection()
            } catch {
                try Task.checkCancellation()
                if attempt == 1 { throw ServiceError.unavailable }
                resetConnection()
            }
        }
        throw ServiceError.unavailable
    }

    private func edge(base: URL, method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0).base64EncodedString() } ?? ""
        let envelope: [String: Any] = ["method": method, "path": path, "body": encoded,
                                       "content_type": body == nil ? "" : "application/json"]
        var request = URLRequest(url: base.appendingPathComponent("api/edge/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ServiceError.invalidResponse }
        guard response.statusCode == 200 else { throw ServiceError.http(response.statusCode) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ServiceError.invalidResponse }
        return object
    }

    private func resolveOrigin() async throws -> URL {
        if let origin { return origin }
        if let resolving { return try await resolving.value }
        let task = Task<URL, Error> { try await self.discover() }
        resolving = task
        do {
            let result = try await task.value
            origin = result; resolving = nil
            defaults.set(result.absoluteString, forKey: "verifiedOrigin")
            return result
        } catch { resolving = nil; throw error }
    }

    private func discover() async throws -> URL {
        let pages = ["https://huang-guo.pages.dev/", "https://huangguoai.pages.dev/"]
        let mirrors = await withTaskGroup(of: [URL].self) { group in
            for page in pages { group.addTask { await self.publishedMirrors(page) } }
            var result: [URL] = []
            for await urls in group { result += urls }
            return result
        }
        var seen = Set<URL>()
        let candidates = (mirrors + [URL(string: "https://huangguoai.com")!, URL(string: "https://huangguoai.ai")!])
            .filter { seen.insert($0).inserted }
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            for candidate in candidates.prefix(6) {
                group.addTask {
                    do {
                        let probe = try await self.edge(base: candidate, method: "GET", path: "/api/videos?page=1&size=1")
                        return Payload.int(probe["status"]) == 1 ? candidate : nil
                    } catch { return nil }
                }
            }
            for try await result in group {
                if let result { group.cancelAll(); return result }
            }
            throw ServiceError.unavailable
        }
    }

    private func publishedMirrors(_ page: String) async -> [URL] {
        do {
            let base = URL(string: page)!
            var request = URLRequest(url: base); request.timeoutInterval = 5
            let (htmlData, _) = try await session.data(for: request)
            let html = String(decoding: htmlData, as: UTF8.self)
            guard let script = PublisherParser.firstCapture("<script[^>]+src=[\"']([^\"']+)", in: html),
                  let scriptURL = URL(string: script, relativeTo: base)?.absoluteURL,
                  scriptURL.scheme == "https", scriptURL.host == base.host else { return [] }
            request = URLRequest(url: scriptURL); request.timeoutInterval = 5
            let (data, _) = try await session.data(for: request)
            return PublisherParser.origins(in: String(decoding: data, as: UTF8.self))
        } catch { return [] }
    }
}

enum PublisherParser {
    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    static func origins(in script: String) -> [URL] {
        guard let array = firstCapture("(?:var|let|const)\\s+urls\\s*=\\s*\\[([^]]+)\\]", in: script),
              let re = try? NSRegularExpression(pattern: "[\"']([a-zA-Z0-9.-]+)/*[\"']") else { return [] }
        return re.matches(in: array, range: NSRange(array.startIndex..., in: array)).prefix(3).compactMap { match in
            guard let range = Range(match.range(at: 1), in: array) else { return nil }
            let host = String(array[range])
            guard host.contains("."), !host.hasPrefix("."), !host.contains(".."), host.first?.isLetter == true else { return nil }
            return URL(string: "https://thu." + host)
        }
    }
}
