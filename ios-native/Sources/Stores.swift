import Foundation
import Combine

@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var records: [WatchRecord] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "watchRecords"),
           let saved = try? JSONDecoder().decode([WatchRecord].self, from: data) {
            records = saved.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
    func record(for id: Int) -> WatchRecord? { records.first { $0.id == id } }
    func save(drama: Drama, episode: Int, position: Double, duration: Double) {
        guard position.isFinite, duration.isFinite, position >= 0, episode > 0 else { return }
        let entry = WatchRecord(drama: drama, episode: episode, position: position,
                                duration: max(duration, 0), updatedAt: Date())
        records.removeAll { $0.id == drama.id }; records.insert(entry, at: 0)
        records = Array(records.prefix(100)); persist()
    }
    func remove(id: Int) { records.removeAll { $0.id == id }; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "watchRecords") }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var items: [Drama] = []
    @Published var loading = false
    @Published var loadingMore = false
    @Published var error: String?
    @Published var total = 0
    private var generation = UUID()
    private var page = 0
    private var pages = 1
    private var query = ""
    private var kind: FeedKind = .latest
    private let service: HGService
    let demo: Bool

    init(service: HGService = .shared, demo: Bool = false) { self.service = service; self.demo = demo }
    var hasMore: Bool { page < pages }

    func reload(kind: FeedKind, query: String, reconnect: Bool = false) async {
        let token = UUID(); generation = token
        self.kind = kind; self.query = query; page = 0; pages = 1
        loading = true; loadingMore = false; error = nil
        defer { if generation == token { loading = false } }
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            if demo {
                items = DemoCatalog.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
                total = items.count; page = 1; pages = 1; return
            }
            if reconnect { await service.resetConnection() }
            let result = try await service.list(page: 1, kind: kind, query: query)
            try Task.checkCancellation(); guard generation == token else { return }
            var seen = Set<Int>(); items = result.items.filter { seen.insert($0.id).inserted }
            page = result.page; pages = result.pages; total = result.total
        } catch is CancellationError { }
        catch { if generation == token { items = []; self.error = error.localizedDescription } }
    }

    func loadMore() async {
        guard !demo, !loading, !loadingMore, hasMore else { return }
        let token = generation; loadingMore = true
        defer { if generation == token { loadingMore = false } }
        do {
            let result = try await service.list(page: page + 1, kind: kind, query: query)
            try Task.checkCancellation(); guard generation == token else { return }
            var seen = Set(items.map(\.id)); items += result.items.filter { seen.insert($0.id).inserted }
            page = result.page; pages = result.pages; error = nil
        } catch is CancellationError { }
        catch { if generation == token { self.error = error.localizedDescription } }
    }
}

enum DemoCatalog {
    static let items = [
        Drama(id: 1, title: "山海来信", episodeCount: 12, tags: ["旅行", "生活"], isFinished: true),
        Drama(id: 2, title: "沿途的光", episodeCount: 8, tags: ["都市", "成长"]),
        Drama(id: 3, title: "慢慢来，也很好", episodeCount: 6, tags: ["生活"], isFinished: true),
        Drama(id: 4, title: "下一站晴天", episodeCount: 10, tags: ["温暖", "日常"])
    ]
}
