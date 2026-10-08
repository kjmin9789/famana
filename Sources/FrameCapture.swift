import Cocoa
import AVFoundation

func isFrameShortcut(key: Int64, flags: CGEventFlags, bundleID: String?) -> Bool {
    key == 1 && bundleID == "com.apple.QuickTimePlayerX"
        && flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskCommand
}

func quickTimeMovieFocused() -> Bool {
    guard let app = NSWorkspace.shared.frontmostApplication,
          app.bundleIdentifier == "com.apple.QuickTimePlayerX" else { return false }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    // Keep a stalled QuickTime accessibility process from disabling the keyboard event tap.
    AXUIElementSetMessagingTimeout(ax, 0.05)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let focused else { return false }
    AXUIElementSetMessagingTimeout(focused as! AXUIElement, 0.05)
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
    guard let role = role as? String,
          ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { return false }
    var window: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
          let window else { return false }
    AXUIElementSetMessagingTimeout(window as! AXUIElement, 0.05)
    var subrole: CFTypeRef?
    AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
    guard subrole as? String == kAXStandardWindowSubrole else { return false }
    var sheets: CFTypeRef?
    AXUIElementCopyAttributeValue(window as! AXUIElement, "AXSheets" as CFString, &sheets)
    return (sheets as? [AXUIElement] ?? []).isEmpty
}

struct MovieFrame {
    let source: SelectedItem
    let seconds: Double

    init(path: String, seconds: Double, modified: Bool, playing: Bool) throws {
        guard !modified else {
            throw RenameFailure(message: "편집 중인 영상입니다. Famana를 OFF로 바꾸고 QuickTime에서 영상을 저장한 뒤 다시 시도하세요.")
        }
        guard !playing else {
            throw RenameFailure(message: "원하는 장면에서 영상을 일시정지한 뒤 ⌘S를 누르세요.")
        }
        guard path.hasPrefix("/"), seconds.isFinite, seconds >= 0 else {
            throw RenameFailure(message: "저장된 로컬 영상의 재생 위치를 확인할 수 없습니다.")
        }
        source = try SelectedItem(URL(fileURLWithPath: path))
        self.seconds = seconds
    }

    // Keep the document reference and time together; never infer a file from Finder selection.
    static let scriptSource = """
        with timeout of 10 seconds
            tell application "QuickTime Player"
                if (count of documents) is 0 then return {}
                set movie to front document
                if modified of movie then return {"", 0, true, false}
                if playing of movie then return {"", 0, false, true}
                return {POSIX path of (file of movie as alias), current time of movie, false, false}
            end tell
        end timeout
        """

    static func current() throws -> MovieFrame {
        let script = NSAppleScript(source: scriptSource)!
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            throw RenameFailure(message: "QuickTime의 영상 정보를 읽지 못했습니다. 저장된 로컬 영상을 열고, 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → Famana에서 QuickTime Player 제어를 허용해 주세요.")
        }
        guard result.numberOfItems == 4, let path = result.atIndex(1)?.stringValue,
              let time = result.atIndex(2), let modified = result.atIndex(3),
              let playing = result.atIndex(4) else {
            throw RenameFailure(message: "QuickTime Player에서 저장된 영상을 열어 주세요.")
        }
        return try MovieFrame(path: path, seconds: time.doubleValue,
                              modified: modified.booleanValue, playing: playing.booleanValue)
    }

    func png() async throws -> Data {
        try source.validate()
        let asset = AVURLAsset(url: source.url)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0,
              seconds <= duration.seconds else {
            throw RenameFailure(message: "영상의 재생 위치가 유효하지 않습니다. 영상을 다시 열어 주세요.")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // At the end, the displayed picture is the last frame, not a frame past EOF.
        let time = seconds == duration.seconds
            ? CMTimeSubtract(duration, CMTime(value: 1, timescale: duration.timescale))
            : CMTime(seconds: seconds, preferredTimescale: 600_000)
        let (image, _) = try await generator.image(at: time)
        try source.validate()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw RenameFailure(message: "장면을 PNG로 변환하지 못했습니다.")
        }
        return data
    }
}

func saveFramePNG(_ data: Data, source: URL, folder: URL,
                  date: Date = Date(), identifier: UUID = UUID()) throws -> URL {
    var name = source.deletingPathExtension().lastPathComponent
    name = name.replacingOccurrences(of: ":", with: "_")
    while name.utf8.count > 150 { name.removeLast() }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
    let target = folder.appendingPathComponent("\(name)_\(formatter.string(from: date))_\(identifier.uuidString).png")
    let temporary = folder.appendingPathComponent(".famana-\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try renameWithoutOverwrite(temporary, to: target)
    return target
}

extension AppDelegate {
    @objc func chooseCaptureFolder() {
        let wasPresenting = presenting
        presenting = true
        defer { presenting = wasPresenting }
        let panel = NSOpenPanel()
        panel.title = "캡처 이미지를 저장할 폴더"
        panel.prompt = "이 폴더에 저장"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = try? captureFolder()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "captureFolder")
        } catch { show("폴더를 기억하지 못했습니다", error.localizedDescription) }
    }

    func captureFolder() throws -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "captureFolder") else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw RenameFailure(message: "저장 폴더가 없습니다. F 우클릭 → 캡처 저장 폴더 선택에서 다시 선택해 주세요.")
        }
        if stale {
            UserDefaults.standard.set(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                          relativeTo: nil), forKey: "captureFolder")
        }
        return url
    }

    func captureFrame() {
        do {
            guard quickTimeMovieFocused() else { savingFrame = false; return }
            let frame = try MovieFrame.current()
            // Snapshot the paused scene before a first-run folder panel changes focus.
            if try captureFolder() == nil { chooseCaptureFolder() }
            guard let folder = try captureFolder() else { savingFrame = false; return }
            if NSApp.isActive {
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.QuickTimePlayerX" }?
                    .activate(options: [])
            }
            Task { @MainActor in
                defer { self.savingFrame = false }
                do {
                    let data = try await frame.png()
                    let target = try saveFramePNG(data, source: frame.source.url, folder: folder)
                    self.item.button?.toolTip = "저장 완료: \(target.lastPathComponent)"
                    self.item.button?.title = "✓"
                    self.item.button?.image = nil
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.refresh()
                } catch {
                    self.show("장면을 저장하지 못했습니다", "\(error.localizedDescription)\n저장 폴더는 F 우클릭 메뉴에서 다시 선택할 수 있습니다.")
                }
            }
        } catch {
            savingFrame = false
            show("장면을 저장하지 못했습니다", "\(error.localizedDescription)\n저장 폴더는 F 우클릭 메뉴에서 다시 선택할 수 있습니다.")
        }
    }
}
