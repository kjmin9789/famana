import Cocoa
import AVFoundation

func frameCaptureCheck() async throws {
    let compiled = await MainActor.run { () -> Bool in
        var error: NSDictionary?
        return NSAppleScript(source: MovieFrame.scriptSource)!.compileAndReturnError(&error)
    }
    precondition(compiled, "QuickTime script does not compile")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("테스트 영상.mov")
    let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 16
    ])
    input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 16, ty: 0)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                      kCVPixelBufferWidthKey as String: 32,
                                      kCVPixelBufferHeightKey as String: 16])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<3 {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard Date() < deadline, writer.status == .writing else {
                throw RenameFailure(message: "Test movie writer timed out")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32ARGB,
            nil, &buffer) == kCVReturnSuccess)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<16 {
            for col in 0..<32 {
                let offset = row * CVPixelBufferGetBytesPerRow(pixelBuffer) + col * 4
                bytes[offset] = 255
                bytes[offset + 1] = index == 0 ? 255 : 0
                bytes[offset + 2] = index == 2 ? 255 : 0
                bytes[offset + 3] = index == 1 ? 255 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        precondition(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
    }
    writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error! }

    var png = Data()
    for (seconds, channel) in [(0.0, 0), (0.5, 0), (1.0, 2), (1.5, 2), (3.0, 1)] {
        let frame = try MovieFrame(path: movie.path, seconds: seconds, modified: false, playing: false)
        png = try await frame.png()
        let image = NSBitmapImageRep(data: png)!
        precondition(image.pixelsWide == 16 && image.pixelsHigh == 32, "Rotation or resolution lost")
        let color = image.colorAt(x: 8, y: 16)!.usingColorSpace(.deviceRGB)!
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        precondition(channels[channel] > 0.8 && channels.enumerated().allSatisfy {
            $0.offset == channel || $0.element < 0.2
        }, "Wrong video frame extracted")
    }
    for (seconds, modified, playing) in [(-1.0, false, false), (.nan, false, false),
                                         (0.0, true, false), (0.0, false, true)] {
        do {
            _ = try MovieFrame(path: movie.path, seconds: seconds, modified: modified, playing: playing)
            preconditionFailure("Unsafe capture accepted")
        } catch is RenameFailure { }
    }
    let beyondEnd = try MovieFrame(path: movie.path, seconds: 4, modified: false, playing: false)
    do { _ = try await beyondEnd.png(); preconditionFailure("Invalid time accepted") }
    catch is RenameFailure { }
    let identifier = UUID()
    let date = Date()
    let source = dir.appendingPathComponent(String(repeating: "한", count: 100) + ".mov")
    let saved = try saveFramePNG(png, source: source, folder: dir, date: date, identifier: identifier)
    precondition(saved.lastPathComponent.utf8.count <= 255)
    let savedData = try Data(contentsOf: saved)
    precondition(savedData == png)
    do {
        _ = try saveFramePNG(Data("wrong".utf8), source: source, folder: dir, date: date, identifier: identifier)
        preconditionFailure("Existing capture overwritten")
    } catch is RenameFailure { }
    let preservedData = try Data(contentsOf: saved)
    precondition(preservedData == png)
    let files = try fm.contentsOfDirectory(atPath: dir.path)
    precondition(files.allSatisfy { !$0.hasPrefix(".famana-") })
    let bookmark = try dir.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    var stale = false
    let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
    precondition(resolved.resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
    precondition(isFrameShortcut(key: 1, flags: .maskCommand, bundleID: "com.apple.QuickTimePlayerX"))
    for flags: CGEventFlags in [[], [.maskCommand, .maskShift], [.maskCommand, .maskAlternate], [.maskCommand, .maskControl]] {
        precondition(!isFrameShortcut(key: 1, flags: flags, bundleID: "com.apple.QuickTimePlayerX"))
    }
    precondition(!isFrameShortcut(key: 1, flags: .maskCommand, bundleID: "com.apple.finder"))
    precondition(!isFrameShortcut(key: 36, flags: .maskCommand, bundleID: "com.apple.QuickTimePlayerX"))
    print("PASS: QuickTime script compilation, exact video frames, EOF, rotation, PNG, validation, filename length, no overwrite, bookmark, shortcut routing")
}
