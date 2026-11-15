import SwiftUI
import CommonCrypto
import ImageIO

actor CoverLoader {
    static let shared = CoverLoader()
    private var cache: [String: UIImage] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    func image(for address: String) async -> UIImage? {
        if let image = cache[address] { return image }
        if let task = inFlight[address] { return await task.value }
        guard let url = URL(string: address), url.scheme == "https" else { return nil }
        let task = Task<UIImage?, Never> {
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 10_000_000 else { return nil }
                if let image = Self.thumbnail(data) { return image }
                guard let plain = Self.decrypt(data) else { return nil }
                return Self.thumbnail(plain)
            } catch { return nil }
        }
        inFlight[address] = task
        let result = await task.value; inFlight[address] = nil
        if let result {
            if cache.count >= 80 { cache.removeValue(forKey: cache.keys.first!) }
            cache[address] = result
        }
        return result
    }

    private nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// HGhubX media.rs cover format: AES-128-CBC, not video DRM.
    nonisolated static func decrypt(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else { return nil }
        let key = Array("f5d965df75336270".utf8), iv = Array("97b60394abc2fbe1".utf8)
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = data.withUnsafeBytes { input in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                    key, key.count, iv, input.baseAddress, data.count, &output, output.count, &written)
        }
        guard status == kCCSuccess else { return nil }
        var result = Data(output.prefix(written))
        if let last = result.last, (1...16).contains(Int(last)), result.count >= Int(last),
           result.suffix(Int(last)).allSatisfy({ $0 == last }) { result.removeLast(Int(last)) }
        return result
    }
}

struct CoverImage: View {
    let drama: Drama
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle").font(.system(size: 34, weight: .ultraLight))
                    Text(drama.title).font(.system(.title3, design: .serif, weight: .medium))
                        .multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.white.opacity(0.9)).padding(18)
            }
        }
        .clipped()
        .task(id: drama.cover) {
            image = nil
            let result = await CoverLoader.shared.image(for: drama.cover)
            if !Task.isCancelled { image = result }
        }
        .accessibilityHidden(true)
    }
    private var palette: [Color] {
        switch drama.id % 4 {
        case 0: return [Color(red: 0.32, green: 0.42, blue: 0.44), Color(red: 0.12, green: 0.21, blue: 0.26)]
        case 1: return [Color(red: 0.38, green: 0.55, blue: 0.51), Color(red: 0.12, green: 0.29, blue: 0.28)]
        case 2: return [Color(red: 0.66, green: 0.53, blue: 0.40), Color(red: 0.33, green: 0.27, blue: 0.24)]
        default: return [Color(red: 0.52, green: 0.50, blue: 0.64), Color(red: 0.25, green: 0.26, blue: 0.38)]
        }
    }
}
