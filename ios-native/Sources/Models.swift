import Foundation

enum Payload {
    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        return Int(value as? String ?? "") ?? 0
    }
    static func string(_ value: Any?) -> String { value as? String ?? "" }
}

struct Drama: Identifiable, Codable, Hashable {
    let id: Int
    var title: String
    var cover: String
    var episodeCount: Int
    var tags: [String]
    var summary: String
    var isFinished: Bool

    init(id: Int, title: String, cover: String = "", episodeCount: Int = 0,
         tags: [String] = [], summary: String = "", isFinished: Bool = false) {
        self.id = id; self.title = title; self.cover = cover
        self.episodeCount = episodeCount; self.tags = tags
        self.summary = summary; self.isFinished = isFinished
    }

    init?(json: [String: Any]) {
        let id = Payload.int(json["id"])
        guard id > 0, let title = json["title"] as? String, !title.isEmpty else { return nil }
        self.init(id: id, title: title, cover: Payload.string(json["cover"]),
                  episodeCount: max(Payload.int(json["episode_count"]), Payload.int(json["total_episodes"])),
                  tags: json["tags"] as? [String] ?? [], summary: Payload.string(json["description"]),
                  isFinished: (json["is_finished"] as? Bool) ?? (Payload.int(json["is_finished"]) == 1))
    }

    var episodeLabel: String {
        guard episodeCount > 0 else { return "剧集" }
        return isFinished ? "全 \(episodeCount) 集" : "更新至 \(episodeCount) 集"
    }
}

struct Episode: Identifiable, Hashable {
    let number: Int
    let title: String
    let duration: Double
    var id: Int { number }
}

struct DramaDetail {
    let drama: Drama
    let episodes: [Episode]

    init(json: [String: Any]) throws {
        guard let drama = Drama(json: json) else { throw ServiceError.invalidResponse }
        self.drama = drama
        let parsed = (json["episodes"] as? [[String: Any]] ?? []).compactMap { item -> Episode? in
            let number = Payload.int(item["ep_num"])
            guard number > 0 else { return nil }
            return Episode(number: number, title: Payload.string(item["title"]),
                           duration: Double(Payload.int(item["duration"])))
        }
        var seen = Set<Int>()
        episodes = parsed.filter { seen.insert($0.number).inserted }.sorted { $0.number < $1.number }
    }
}

struct DramaPage {
    let items: [Drama]
    let page: Int
    let pages: Int
    let total: Int
    init(json: [String: Any]) {
        items = (json["items"] as? [[String: Any]] ?? []).compactMap(Drama.init(json:))
        let pagination = json["pagination"] as? [String: Any] ?? [:]
        page = max(Payload.int(pagination["page"]), 1)
        pages = max(Payload.int(pagination["pages"]), page)
        total = max(Payload.int(pagination["total"]), items.count)
    }
}

enum FeedKind: String, CaseIterable, Identifiable {
    case latest = "最新", original = "原创"
    var id: Self { self }
}

enum ServiceError: LocalizedError {
    case unavailable, invalidResponse, noStream, http(Int), business(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法连接，请检查网络后重试。"
        case .invalidResponse: return "内容暂时无法读取，请稍后重试。"
        case .noStream: return "这一集暂时没有可播放的完整视频源。"
        case .http: return "服务暂时不可用，请稍后重试。"
        case .business(let message): return message.isEmpty ? "内容暂时不可用。" : message
        }
    }
}

struct PlaybackSource {
    let url: URL
    let fallback: URL?

    static func parse(_ json: [String: Any]) -> PlaybackSource? {
        let streams = json["streams"] as? [String: Any] ?? [:]
        func valid(_ value: Any?) -> URL? {
            guard let string = value as? String, let url = URL(string: string),
                  url.scheme == "https", url.host != nil else { return nil }
            return url
        }
        let main = valid(streams["main"]) ?? valid(json["video_url"])
        let hevc = valid(streams["hevc"]) ?? valid(json["video_url_hevc"])
        // A preview is deliberately never promoted to a full episode.
        guard let url = main ?? hevc else { return nil }
        return PlaybackSource(url: url, fallback: main != nil && hevc != main ? hevc : nil)
    }
}

struct WatchRecord: Identifiable, Codable {
    var drama: Drama
    var episode: Int
    var position: Double
    var duration: Double
    var updatedAt: Date
    var id: Int { drama.id }
    var progress: Double { duration > 0 ? min(max(position / duration, 0), 1) : 0 }
}
