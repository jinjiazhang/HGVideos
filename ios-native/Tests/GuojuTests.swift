import XCTest
import AVFoundation
@testable import Guoju

final class GuojuTests: XCTestCase {
    func testDetailNormalizesEpisodesWithoutInventingPaidEntries() throws {
        let result = try DramaDetail(json: ["id": "10", "title": "示例", "episode_count": "6", "episodes": [
            ["ep_num": 3, "duration": 200], ["ep_num": "1"], ["ep_num": 3], ["ep_num": 0]
        ]])
        XCTAssertEqual(result.drama.id, 10)
        XCTAssertEqual(result.drama.episodeCount, 6)
        XCTAssertEqual(result.episodes.map(\.number), [1, 3])
    }
    func testPreviewIsNeverUsedAsFullEpisode() {
        XCTAssertNil(PlaybackSource.parse(["streams": ["preview": "https://example.com/trial.m3u8"]]))
        XCTAssertNil(PlaybackSource.parse(["streams": ["main": "file:///private/video", "preview": "https://example.com/trial"]]))
        let value = PlaybackSource.parse(["streams": ["main": "https://example.com/full", "hevc": "https://example.com/hevc"]])
        XCTAssertEqual(value?.url.path, "/full")
        XCTAssertEqual(value?.fallback?.path, "/hevc")
    }
    func testPublishedMirrorsAreParsedAsData() {
        let value = PublisherParser.origins(in: "var urls=['one.example/','two.example/']; doNotExecute();")
        XCTAssertEqual(value.map(\.host), ["thu.one.example", "thu.two.example"])
        XCTAssertTrue(PublisherParser.origins(in: "var urls=['https://evil.example','../host','user@host.example'];").isEmpty)
    }
    @MainActor func testResumeSurvivesRelaunchAndDeletion() throws {
        let suite = "GuojuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchStore(defaults: defaults)
        store.save(drama: DemoCatalog.items[0], episode: 2, position: 51, duration: 220)
        store.save(drama: DemoCatalog.items[0], episode: 3, position: .nan, duration: 220)
        let restored = WatchStore(defaults: defaults)
        XCTAssertEqual(restored.records.count, 1)
        XCTAssertEqual(restored.records.first?.episode, 2)
        XCTAssertEqual(restored.records.first?.position, 51)
        restored.remove(id: DemoCatalog.items[0].id)
        XCTAssertTrue(WatchStore(defaults: defaults).records.isEmpty)
    }

    /// Explicit live integration test. No signed URL or decoded image is written to disk.
    @MainActor func testLiveCatalogAndSustainedNativePlayback() async throws {
        let suite = "GuojuLive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HGService(defaults: defaults)
        let feed = try await service.list(page: 1, kind: .latest)
        XCTAssertFalse(feed.items.isEmpty)
        let search = try await service.list(page: 1, kind: .latest, query: "穿越三角洲")
        XCTAssertTrue(search.items.contains(where: { $0.id == 8424 }))
        let detail = try await service.detail(id: 8424)
        XCTAssertGreaterThanOrEqual(detail.episodes.count, 3)
        let history = WatchStore(defaults: defaults)
        history.save(drama: detail.drama, episode: 2, position: 0, duration: 0)
        let model = PlaybackModel(drama: detail.drama, history: history, service: service)
        defer { model.close() }
        await model.load()
        try await eventually(seconds: 75) { model.ready || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.ready)
        XCTAssertEqual(model.currentEpisode, 2)
        XCTAssertGreaterThan(model.duration, 180)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        model.player.currentItem?.add(output)
        try await eventually(seconds: 45) { model.position > 22 || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertGreaterThan(model.position, 22, "Must advance continuously beyond the 15-second preview boundary")
        let frame = output.copyPixelBuffer(forItemTime: model.player.currentTime(), itemTimeForDisplay: nil)
        XCTAssertNotNil(frame, "Native decoder must produce a video frame")
        print("LIVE_CHECK episode=2 duration=\(model.duration) continuous=\(model.position) decodedFrame=\(frame != nil)")
        model.player.pause(); model.saveProgress()
        XCTAssertEqual(history.record(for: 8424)?.episode, 2)
        XCTAssertGreaterThan(history.record(for: 8424)?.position ?? 0, 22)
        await model.player.seek(to: CMTime(seconds: 90, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.player.play()
        try await eventually(seconds: 30) { model.position > 95 || model.error != nil }
        XCTAssertGreaterThan(model.position, 95)
        print("LIVE_CHECK episode=2 seekPosition=\(model.position)")
        model.select(3)
        try await eventually(seconds: 60) { model.ready || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentEpisode, 3)
        XCTAssertGreaterThan(model.duration, 180)
        try await eventually(seconds: 40) { model.position > 18 || model.error != nil }
        XCTAssertGreaterThan(model.position, 18)
        print("LIVE_CHECK episode=3 duration=\(model.duration) continuous=\(model.position)")
    }

    @MainActor func testLiveCoverResumeAndAutomaticNext() async throws {
        let suite = "GuojuResume.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HGService(defaults: defaults)
        let detail = try await service.detail(id: 8424)
        let cover = await CoverLoader.shared.image(for: detail.drama.cover)
        XCTAssertNotNil(cover)
        XCTAssertLessThanOrEqual(max(cover?.size.width ?? 0, cover?.size.height ?? 0), 640)
        let history = WatchStore(defaults: defaults)
        history.save(drama: detail.drama, episode: 2, position: 93, duration: 221.267)
        let model = PlaybackModel(drama: detail.drama, history: history, service: service)
        defer { model.close() }
        await model.load()
        try await eventually(seconds: 65) { model.position > 94 || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentEpisode, 2)
        XCTAssertGreaterThan(model.position, 94)
        await model.player.seek(to: CMTime(seconds: model.duration - 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        model.player.play()
        try await eventually(seconds: 45) { (model.currentEpisode == 3 && model.position > 1) || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(model.currentEpisode, 3)
        XCTAssertGreaterThan(model.position, 1)
        print("LIVE_CHECK coverDecoded=\(cover != nil) resumedAfter=94 automaticNextEpisode=\(model.currentEpisode)")
    }

    @MainActor private func eventually(seconds: Double, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        XCTAssertTrue(condition(), "Timed out after \(seconds) seconds")
    }
}
