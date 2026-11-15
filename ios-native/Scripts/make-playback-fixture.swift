// Development-only neutral video for testing full-screen presentation.
// Copy the result into the unsigned simulator .app, never the device package.
import AVFoundation
import CoreGraphics
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 640, AVVideoHeightKey: 360
])
let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360
])
writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
for frame in 0..<600 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &buffer)
    CVPixelBufferLockBaseAddress(buffer!, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: 640, height: 360,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!),
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    context.setFillColor(CGColor(red: 0.08, green: 0.3, blue: 0.28, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    context.setFillColor(CGColor(red: 0.9, green: 0.85, blue: 0.65, alpha: 1))
    context.fill(CGRect(x: (frame * 7) % 580, y: 140, width: 60, height: 80))
    CVPixelBufferUnlockBaseAddress(buffer!, [])
    adapter.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 2))
}
input.markAsFinished()
let semaphore = DispatchSemaphore(value: 0)
writer.finishWriting { semaphore.signal() }; semaphore.wait()
guard writer.status == .completed else { fatalError("Fixture encoding failed") }
