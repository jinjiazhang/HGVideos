import SwiftUI
import AVKit

@main
struct GuojuApp: App {
    @StateObject private var history = WatchStore()
    private var demo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-demo") || ProcessInfo.processInfo.arguments.contains("--unit-tests")
        #else
        false
        #endif
    }
    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryScreen(history: history, demo: demo)
                    .tabItem { Label("剧集", systemImage: "rectangle.stack") }
                HistoryScreen(history: history, demo: demo)
                    .tabItem { Label("继续看", systemImage: "play.circle") }
            }
            .tint(Color(red: 0.12, green: 0.43, blue: 0.40))
        }
    }
}

struct LibraryScreen: View {
    @StateObject private var model: LibraryModel
    @ObservedObject var history: WatchStore
    @State private var query = ""
    @State private var kind: FeedKind = .latest
    @State private var about = false
    let demo: Bool
    init(history: WatchStore, demo: Bool) {
        self.history = history; self.demo = demo
        _model = StateObject(wrappedValue: LibraryModel(demo: demo))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if model.loading {
                        ProgressView("正在加载剧集").frame(maxWidth: .infinity, minHeight: 260)
                    } else if model.items.isEmpty {
                        ContentUnavailableView {
                            Label(model.error == nil ? "没有找到剧集" : "暂时连接不上", systemImage: "rectangle.stack")
                        } description: {
                            Text(model.error ?? "换个关键词再试试。")
                        } actions: {
                            if model.error != nil { Button("重新连接") { Task { await reload(reconnect: true) } }.buttonStyle(.bordered) }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 24) {
                            ForEach(model.items) { drama in
                                NavigationLink(value: drama) { DramaCard(drama: drama) }.buttonStyle(.plain)
                                    .task { if drama.id == model.items.last?.id { await model.loadMore() } }
                            }
                        }
                        if model.loadingMore { ProgressView().frame(maxWidth: .infinity) }
                        if model.error != nil {
                            Button("加载下一页失败，点此重试") { Task { await model.loadMore() } }.frame(maxWidth: .infinity)
                        }
                    }
                }.padding(20)
            }
            .navigationTitle("剧集")
            .searchable(text: $query, prompt: "搜索剧名")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("分类", selection: $kind) {
                            ForEach(FeedKind.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(kind.rawValue).font(.subheadline)
                            Image(systemName: "chevron.down").font(.caption2)
                        }
                    }.accessibilityLabel("剧集分类，当前\(kind.rawValue)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { about = true } label: { Image(systemName: "info.circle") }.accessibilityLabel("关于果剧")
                }
            }
            .navigationDestination(for: Drama.self) { PlayerScreen(drama: $0, history: history, demo: demo) }
            .refreshable { await reload() }
            .sheet(isPresented: $about) { AboutScreen() }
        }
        // Keep the loaded pages and scroll view intact when popping the player.
        .task(id: "\(kind.rawValue)|\(query)") { await reload() }
    }
    private func reload(reconnect: Bool = false) async { await model.reload(kind: kind, query: query, reconnect: reconnect) }
}

struct DramaCard: View {
    let drama: Drama
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverImage(drama: drama).aspectRatio(0.70, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(drama.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(drama.episodeLabel).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct HistoryScreen: View {
    @ObservedObject var history: WatchStore
    let demo: Bool
    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView("从一部好剧开始", systemImage: "play.circle", description: Text("看过的剧集会留在这里，随时接着看。"))
                } else {
                    List {
                        ForEach(history.records) { record in
                            NavigationLink(value: record.drama) {
                                HStack(spacing: 16) {
                                    CoverImage(drama: record.drama).frame(width: 68, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(record.drama.title).font(.headline).lineLimit(2)
                                        Text("第 \(record.episode) 集 · 已看 \(Int(record.position) / 60) 分 \(Int(record.position) % 60) 秒").font(.caption).foregroundStyle(.secondary)
                                        ProgressView(value: record.progress)
                                    }
                                }.padding(.vertical, 6)
                            }.swipeActions { Button("删除", role: .destructive) { history.remove(id: record.id) } }
                        }
                    }.listStyle(.plain)
                }
            }.navigationTitle("继续看")
                .navigationDestination(for: Drama.self) { PlayerScreen(drama: $0, history: history, demo: demo) }
        }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var onFullScreenChange: (Bool) -> Void = { _ in }
    func makeCoordinator() -> Coordinator { Coordinator(onFullScreenChange: onFullScreenChange) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player; controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        context.coordinator.onFullScreenChange = onFullScreenChange
    }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onFullScreenChange: (Bool) -> Void
        init(onFullScreenChange: @escaping (Bool) -> Void) { self.onFullScreenChange = onFullScreenChange }
        func playerViewController(_ playerViewController: AVPlayerViewController, willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            onFullScreenChange(true)
        }
        func playerViewController(_ playerViewController: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            let player = playerViewController.player
            let wasPlaying = (player?.rate ?? 0) > 0
            coordinator.animate(alongsideTransition: nil) { context in
                if !context.isCancelled {
                    self.onFullScreenChange(false)
                    if wasPlaying { player?.play() }
                }
            }
        }
    }
}

struct FullScreenPresenter: UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var isPresented: Bool
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ host: UIViewController, context: Context) {
        if isPresented, host.presentedViewController == nil, host.view.window != nil {
            let controller = PresentedPlayerController()
            controller.player = player
            controller.videoGravity = .resizeAspect
            controller.modalPresentationStyle = .fullScreen
            controller.onDismiss = { isPresented = false }
            host.present(controller, animated: true)
        } else if !isPresented, host.presentedViewController != nil {
            host.dismiss(animated: true)
        }
    }
    // Present AVKit itself so its system Close control dismisses the actual
    // modal controller, rather than an unrelated SwiftUI hosting controller.
    final class PresentedPlayerController: AVPlayerViewController {
        var onDismiss: (() -> Void)?
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            let activePlayer = player
            let wasPlaying = (activePlayer?.rate ?? 0) > 0
            transitionCoordinator?.animate(alongsideTransition: nil) { context in
                if !context.isCancelled, wasPlaying { activePlayer?.play() }
            }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if presentingViewController == nil { onDismiss?(); onDismiss = nil }
        }
    }
}

struct PlayerScreen: View {
    @StateObject private var model: PlaybackModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var fullScreen = false
    @State private var systemFullScreen = false
    let demo: Bool
    init(drama: Drama, history: WatchStore, demo: Bool) {
        self.demo = demo
        _model = StateObject(wrappedValue: PlaybackModel(drama: drama, history: history, demo: demo))
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color.black
                        if !fullScreen {
                            NativePlayer(player: model.player) { systemFullScreen = $0 }
                        }
                        if model.loading { ProgressView("准备播放").tint(.white).foregroundStyle(.white) }
                        if let error = model.error {
                            VStack(spacing: 14) {
                                Image(systemName: "wifi.exclamationmark").font(.title)
                                Text(error).font(.callout).multilineTextAlignment(.center)
                                Button("重试") { model.retry() }.buttonStyle(.borderedProminent)
                            }.padding(30).foregroundStyle(.white)
                        }
                        if demo { Label("界面预览", systemImage: "play.rectangle").foregroundStyle(.white.opacity(0.6)) }
                    }.frame(height: min(geometry.size.height * 0.58, geometry.size.width * 1.25))
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.drama.title).font(.title2.bold())
                            HStack {
                                Text("第 \(model.currentEpisode) 集 · \(model.drama.episodeLabel)").foregroundStyle(.secondary)
                                Spacer()
                                if model.episodes.contains(where: { $0.number > model.currentEpisode }) {
                                    Button { model.next() } label: { Label("下一集", systemImage: "forward.end.fill") }
                                }
                            }.font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text("选集").font(.headline); Spacer(); Text("播完自动下一集").font(.caption).foregroundStyle(.secondary) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 10)], spacing: 10) {
                                ForEach(model.episodes) { episode in
                                    Button { model.select(episode.number) } label: {
                                        Text(String(episode.number)).font(.body.monospacedDigit().weight(.medium))
                                            .frame(maxWidth: .infinity).frame(height: 46)
                                            .background(model.currentEpisode == episode.number ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }.accessibilityLabel("第 \(episode.number) 集")
                                }
                            }
                        }
                        if !model.drama.summary.isEmpty {
                            DisclosureGroup("剧情简介") { Text(model.drama.summary).font(.callout).foregroundStyle(.secondary).padding(.top, 8) }
                        }
                    }.padding(20)
                }
            }
        }
        .navigationTitle("播放").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { fullScreen = true } label: {
                    Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right")
                }.accessibilityLabel("全屏播放")
            }
        }
        .background { FullScreenPresenter(player: model.player, isPresented: $fullScreen).frame(width: 0, height: 0) }
        .task { await model.load() }
        // Presenting a full-screen player also hides this screen. Only leaving
        // the episode page should release the player and its current item.
        .onDisappear { if !fullScreen && !systemFullScreen { model.close() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveProgress() } }
    }
}

struct AboutScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var host = "自动选择"
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("版本", value: "1.0.0")
                    Text("专注剧集与播放。观看进度保存在此设备。")
                }
                Section("连接") {
                    LabeledContent("当前线路", value: host)
                    Button("重新选择线路") { Task { await HGService.shared.resetConnection(); host = "下次加载时自动选择" } }
                }
                Section("开源致谢") {
                    Text("接口与封面处理参考 HGhubX。")
                    Link("HGhubX 项目", destination: URL(string: "https://github.com/zxsos/HGhubX")!)
                    NavigationLink("许可与版权声明") {
                        ScrollView { Text(license).font(.footnote).textSelection(.enabled).padding(20) }.navigationTitle("开源许可")
                    }
                }
            }.navigationTitle("果剧").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { host = await HGService.shared.currentHost() }
        }
    }
    private var license: String {
        let notice = "Required Notice: Copyright (c) 2026 HGhubX contributors (https://github.com/zxsos/HGhubX)\n\n"
        return notice + (Bundle.main.url(forResource: "HGhubX-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0) } ?? "")
    }
}
