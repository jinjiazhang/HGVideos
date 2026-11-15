import AVFoundation
import Combine

@MainActor
final class PlaybackModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var drama: Drama
    @Published private(set) var episodes: [Episode] = []
    @Published private(set) var currentEpisode = 1
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var ready = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    private let service: HGService
    private let history: WatchStore
    private let demo: Bool
    private var requestTask: Task<Void, Never>?
    private var requestID = UUID()
    private var statusObserver: NSKeyValueObservation?
    private var completionObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var lastSaved = -10.0
    private var resumePosition = 0.0
    private var fallback: URL?
    private var closed = false

    init(drama: Drama, history: WatchStore, service: HGService = .shared, demo: Bool = false) {
        self.drama = drama; self.history = history; self.service = service; self.demo = demo
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.closed, time.seconds.isFinite else { return }
                self.position = time.seconds
                let duration = self.player.currentItem?.duration.seconds ?? 0
                if duration.isFinite, duration > 0 { self.duration = duration }
                if self.ready, abs(time.seconds - self.lastSaved) >= 5 {
                    self.lastSaved = time.seconds; self.saveProgress()
                }
            }
        }
    }

    func load() async {
        guard episodes.isEmpty, !closed else { return }
        loading = true; error = nil
        if demo {
            episodes = (1...max(drama.episodeCount, 1)).map { Episode(number: $0, title: "第 \($0) 集", duration: 0) }
            loading = false
            select(1)
            return
        }
        do {
            let detail = try await service.detail(id: drama.id)
            try Task.checkCancellation(); guard !closed else { return }
            drama = detail.drama; episodes = detail.episodes
            guard let first = episodes.first else { throw ServiceError.noStream }
            let record = history.record(for: drama.id)
            let episode = episodes.first { $0.number == record?.episode } ?? first
            let resume = record?.episode == episode.number ? record?.position ?? 0 : 0
            select(episode.number, resume: resume)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; loading = false }
    }

    func select(_ number: Int, resume: Double = 0) {
        guard episodes.contains(where: { $0.number == number }), !closed else { return }
        saveProgress(); requestTask?.cancel(); clearItemObservers()
        player.pause(); player.replaceCurrentItem(with: nil)
        currentEpisode = number; position = 0; duration = 0; ready = false
        error = nil; loading = !demo; lastSaved = -10
        let token = UUID(); requestID = token; resumePosition = max(resume, 0)
        #if DEBUG
        if demo, let sample = Bundle.main.url(forResource: "PlaybackDemo", withExtension: "mp4") {
            install(sample, token: token)
            return
        }
        #endif
        guard !demo else { return }
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.service.playback(id: self.drama.id, episode: number)
                try Task.checkCancellation()
                guard self.requestID == token, !self.closed else { return }
                self.fallback = source.fallback
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                self.install(source.url, token: token)
            } catch is CancellationError { }
            catch {
                guard self.requestID == token, !self.closed else { return }
                self.error = error.localizedDescription; self.loading = false
            }
        }
    }

    private func install(_ url: URL, token: UUID) {
        clearItemObservers()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, self.requestID == token, !self.closed,
                      self.player.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.ready = true; self.loading = false; self.error = nil
                    let actual = item.duration.seconds
                    self.duration = actual.isFinite ? actual : 0
                    let target = self.resumePosition
                    self.resumePosition = 0
                    if target > 0, actual.isFinite, target < actual - 3 {
                        self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                            Task { @MainActor in if self?.requestID == token, self?.closed == false { self?.player.play() } }
                        }
                    } else { self.player.play() }
                } else if item.status == .failed { self.handleFailure(token: token) }
            }
        }
        completionObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.requestID == token, !self.closed else { return }
                self.saveProgress()
                if let next = self.episodes.first(where: { $0.number > self.currentEpisode }) { self.select(next.number) }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleFailure(token: token) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func handleFailure(token: UUID) {
        guard requestID == token, !closed else { return }
        if let fallback {
            self.fallback = nil; resumePosition = position
            install(fallback, token: token)
        } else { loading = false; ready = false; error = "视频暂时无法播放，请重试或选择其他集。" }
    }
    func retry() {
        if episodes.isEmpty { Task { await load() } }
        else { select(currentEpisode, resume: position) }
    }
    func next() {
        if let next = episodes.first(where: { $0.number > currentEpisode }) { select(next.number) }
    }
    func saveProgress() {
        guard ready, position > 0 else { return }
        history.save(drama: drama, episode: currentEpisode, position: position, duration: duration)
    }
    func close() {
        saveProgress(); closed = true; requestTask?.cancel(); player.pause()
        clearItemObservers(); player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func clearItemObservers() {
        statusObserver?.invalidate(); statusObserver = nil
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver); self.completionObserver = nil }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver); self.failureObserver = nil }
    }
    deinit {
        requestTask?.cancel(); statusObserver?.invalidate()
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}
