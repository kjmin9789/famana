import Cocoa
import ApplicationServices
import Darwin

func statusIcon(enabled: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let context = NSGraphicsContext.current!.cgContext
        // Original F.svg outline and proportions, without the file frame or rounding.
        let scale = 16.0 / 396.281
        let letter = CGMutablePath()
        letter.addLines(between: [
            CGPoint(x: 0, y: 396.281), CGPoint(x: 0, y: 0),
            CGPoint(x: 214.857, y: 0), CGPoint(x: 214.857, y: 90.7744),
            CGPoint(x: 93.6856, y: 90.7744), CGPoint(x: 93.6856, y: 164.876),
            CGPoint(x: 214.857, y: 164.876), CGPoint(x: 214.857, y: 254.592),
            CGPoint(x: 93.6856, y: 254.592), CGPoint(x: 93.6855, y: 396.281)
        ].map { CGPoint(x: 2 + $0.x * scale, y: 17 - $0.y * scale) })
        letter.closeSubpath()
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.addPath(letter)
        context.fillPath()
        let dot = NSBezierPath(ovalIn: NSRect(x: 11, y: 0.5, width: 6.5, height: 6.5))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        dot.lineWidth = 2
        dot.stroke()
        NSGraphicsContext.restoreGraphicsState()
        (enabled ? NSColor(srgbRed: 0.12, green: 0.76, blue: 0.36, alpha: 1)
                 : NSColor(srgbRed: 0.57, green: 0.59, blue: 0.62, alpha: 1)).setFill()
        dot.fill()
        return true
    }
    image.isTemplate = false // Preserve the green/gray status dot in either menu bar appearance.
    image.accessibilityDescription = enabled ? "Famana 켜짐" : "Famana 꺼짐"
    return image
}

final class PrefixField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused {
            // Wait until the field editor is focused, including inside NSAlert's modal loop.
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(startVoice), object: nil)
            perform(#selector(startVoice), with: nil, afterDelay: 0,
                    inModes: [.modalPanel, .common])
        }
        return focused
    }

    @objc private func startVoice() {
        guard let window, window.isKeyWindow, window.isVisible,
              let editor = currentEditor(), window.firstResponder === editor else { return }
        // ponytail: reuse macOS's native Dictation menu action. It is not a public
        // typed API; use Speech.framework if a future macOS removes this action.
        let action = Selector(("startDictation:"))
        guard NSApp.target(forAction: action) != nil,
              NSApp.sendAction(action, to: nil, from: self) else {
            placeholderString = "자동 시작 불가 · 받아쓰기 단축키 또는 키보드를 사용하세요"
            return
        }
    }
}

struct RenameFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func targetURL(for source: URL, prefix: String) throws -> URL {
    let text = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw RenameFailure(message: "접두어를 입력해 주세요.") }
    guard !text.contains("/"), !text.contains(":"),
          !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw RenameFailure(message: "접두어에 /, : 또는 줄바꿈을 사용할 수 없습니다.")
    }
    let name = text + " " + source.lastPathComponent
    guard name.utf8.count <= 255 else { throw RenameFailure(message: "파일 이름이 너무 깁니다.") }
    return source.deletingLastPathComponent().appendingPathComponent(name)
}

func renameWithoutOverwrite(_ source: URL, to target: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { from in
        target.withUnsafeFileSystemRepresentation { to in
            renamex_np(from!, to!, UInt32(RENAME_EXCL))
        }
    }
    guard result == 0 else {
        let code = errno
        throw RenameFailure(message: code == EEXIST
            ? "같은 이름이 이미 있습니다. 기존 파일은 덮어쓰지 않았습니다."
            : "이름을 바꾸지 못했습니다: " + String(cString: strerror(code)))
    }
}

// Snapshot identity so a replaced selection cannot be renamed accidentally.
struct SelectedItem {
    let url: URL
    let inode: NSNumber
    let device: NSNumber

    init(_ url: URL) throws {
        self.url = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = attrs[.systemFileNumber] as? NSNumber,
              let device = attrs[.systemNumber] as? NSNumber else {
            throw RenameFailure(message: "파일 정보를 읽을 수 없습니다: " + url.lastPathComponent)
        }
        self.inode = inode
        self.device = device
    }

    func validate() throws {
        let current = try SelectedItem(url)
        guard inode == current.inode, device == current.device else {
            throw RenameFailure(message: "선택한 파일이 바뀌었습니다. 다시 선택해 주세요: " + url.lastPathComponent)
        }
    }
}

func renamePlan(_ items: [SelectedItem], prefix: String) throws -> [(SelectedItem, URL)] {
    // Children first also permits a folder and its contents selected in Finder search.
    try items.sorted { $0.url.pathComponents.count > $1.url.pathComponents.count }.map { item in
        try item.validate()
        let target = try targetURL(for: item.url, prefix: prefix)
        // attributesOfItem also detects dangling symlinks, unlike fileExists.
        if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
            throw RenameFailure(message: "같은 이름이 이미 있습니다: " + target.lastPathComponent)
        }
        return (item, target)
    }
}

func applyRenames(_ plan: [(SelectedItem, URL)]) throws {
    // ponytail: filesystem batches are not atomic; stop and report partial success.
    // A transactional journal is only needed if automatic recovery is added.
    for (index, entry) in plan.enumerated() {
        do {
            try entry.0.validate()
            try renameWithoutOverwrite(entry.0.url, to: entry.1)
        } catch {
            throw RenameFailure(message: "총 \(plan.count)개 중 \(index)개 변경 후 중단했습니다. 나머지는 변경하지 않았습니다.\n실패 항목: \(entry.0.url.lastPathComponent)\n\(error.localizedDescription)\nFinder에서 결과를 확인하고 변경하지 않은 항목만 다시 선택해 주세요.")
        }
    }
}

func selfCheck() throws {
    _ = NSApplication.shared
    precondition(NSApp.target(forAction: Selector(("startDictation:"))) != nil,
                 "Native Dictation action is unavailable on this Mac")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let source = dir.appendingPathComponent("사진.tar.gz")
    try Data("original".utf8).write(to: source)
    let target = try targetURL(for: source, prefix: "  여행  ")
    precondition(target.lastPathComponent == "여행 사진.tar.gz")
    for invalid in ["", "  ", "a/b", "a:b", "a\nb", String(repeating: "가", count: 100)] {
        do { _ = try targetURL(for: source, prefix: invalid); preconditionFailure("invalid accepted") }
        catch is RenameFailure { }
    }
    try Data("existing".utf8).write(to: target)
    do { try renameWithoutOverwrite(source, to: target); preconditionFailure("overwritten") }
    catch is RenameFailure { }
    let original = try Data(contentsOf: source)
    let existing = try Data(contentsOf: target)
    precondition(original == Data("original".utf8) && existing == Data("existing".utf8))
    try fm.removeItem(at: target)
    try renameWithoutOverwrite(source, to: target)
    precondition(!fm.fileExists(atPath: source.path))
    let renamed = try Data(contentsOf: target)
    precondition(renamed == original)
    let batch = ["첫째.txt", "둘째.tar.gz", "폴더"] .map { dir.appendingPathComponent($0) }
    try Data("one".utf8).write(to: batch[0])
    try Data("two".utf8).write(to: batch[1])
    try fm.createDirectory(at: batch[2], withIntermediateDirectories: false)
    let nested = batch[2].appendingPathComponent("안쪽.txt")
    try Data("inside".utf8).write(to: nested)
    let selected = try (batch + [nested]).map(SelectedItem.init)
    let conflict = try targetURL(for: batch[1], prefix: "업무")
    try Data("keep".utf8).write(to: conflict)
    do { _ = try renamePlan(selected, prefix: "업무"); preconditionFailure("collision accepted") }
    catch is RenameFailure { }
    precondition(batch.allSatisfy { fm.fileExists(atPath: $0.path) })
    try fm.removeItem(at: conflict)
    try applyRenames(renamePlan(selected, prefix: "업무"))
    precondition(batch.allSatisfy { !fm.fileExists(atPath: $0.path) })
    let one = try Data(contentsOf: dir.appendingPathComponent("업무 첫째.txt"))
    let two = try Data(contentsOf: dir.appendingPathComponent("업무 둘째.tar.gz"))
    let inside = try Data(contentsOf: dir.appendingPathComponent("업무 폴더/업무 안쪽.txt"))
    precondition(one == Data("one".utf8) && two == Data("two".utf8) && inside == Data("inside".utf8))
    // A collision appearing after preflight must still never overwrite a file.
    let next = try ["업무 첫째.txt", "업무 둘째.tar.gz"].map { try SelectedItem(dir.appendingPathComponent($0)) }
    let plan = try renamePlan(next, prefix: "완료")
    try Data("late conflict".utf8).write(to: plan[1].1)
    do { try applyRenames(plan); preconditionFailure("late collision accepted") }
    catch is RenameFailure { }
    precondition(!fm.fileExists(atPath: plan[0].0.url.path))
    precondition(fm.fileExists(atPath: plan[1].0.url.path))
    let preserved = try Data(contentsOf: plan[1].1)
    precondition(preserved == Data("late conflict".utf8))
    print("PASS: validation, single/batch rename, original suffix and contents, nested folders, preflight and late collisions")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var item: NSStatusItem!
    var tap: CFMachPort?
    var enabled = false
    var presenting = false
    var swallowedKey: Int64?
    var input: NSTextField?
    var preview: NSTextField?
    var originalName = ""
    var selectionCount = 0
    var savingFrame = false
    var saveToast: NSPanel?
    var saveToastDismissal: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refresh()
        let menu = NSMenu()
        let edit = NSMenuItem(title: "편집", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "편집")
        for (title, action, key) in [("잘라내기", "cut:", "x"), ("복사", "copy:", "c"),
                                     ("붙여넣기", "paste:", "v"), ("전체 선택", "selectAll:", "a")] {
            submenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = submenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    func refresh() {
        item.button?.title = ""
        item.button?.image = statusIcon(enabled: enabled)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Famana \(enabled ? "ON" : "OFF") · 클릭: 켜기/끄기 · 오른쪽 클릭: 설정 및 종료"
        item.button?.setAccessibilityLabel(enabled ? "Famana 켜짐" : "Famana 꺼짐")
    }

    @objc func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            for (title, action) in [("캡처 저장 폴더 선택…", #selector(chooseCaptureFolder)),
                                    ("사용 방법", #selector(help)), ("손쉬운 사용 권한", #selector(permissions)),
                                    ("받아쓰기 설정", #selector(dictationSettings)), ("종료", #selector(quit))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self
            }
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if enabled { enabled = false; refresh(); return }
        guard AXIsProcessTrusted() else {
            show("권한을 한 번 허용해 주세요", "시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 Famana를 켜 주세요. 이후 메뉴 막대를 다시 클릭하세요.")
            permissions()
            return
        }
        if tap == nil {
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue),
                callback: { _, type, event, info in
                    let app = Unmanaged<AppDelegate>.fromOpaque(info!).takeUnretainedValue()
                    return app.handle(type, event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { show("활성화할 수 없습니다", "손쉬운 사용 권한을 확인한 뒤 앱을 종료하고 다시 실행해 주세요."); return }
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        enabled = true
        refresh()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if swallowedKey == key {
            if type == .keyUp { swallowedKey = nil }
            return nil
        }
        if type == .keyDown, enabled, !presenting,
           isFrameShortcut(key: key, flags: event.flags,
                           bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
           quickTimeMovieFocused() {
            swallowedKey = key
            if !savingFrame {
                savingFrame = true
                DispatchQueue.main.async { self.captureFrame() }
            }
            return nil
        }
        guard type == .keyDown, enabled, !presenting, key == 36 || key == 76,
              event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
              let finder = NSWorkspace.shared.frontmostApplication,
              finder.bundleIdentifier == "com.apple.finder" else { return Unmanaged.passUnretained(event) }
        // Do not intercept Enter in Finder search, Go to Folder, or an existing name editor.
        var focused: CFTypeRef?
        let ax = AXUIElementCreateApplication(finder.processIdentifier)
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return Unmanaged.passUnretained(event) }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        guard let role = role as? String,
              ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
            return Unmanaged.passUnretained(event)
        }
        swallowedKey = key
        presenting = true
        DispatchQueue.main.async { self.prompt() }
        return nil
    }

    func prompt() {
        defer { presenting = false }
        let script = NSAppleScript(source: """
        tell application "Finder"
            set chosen to selection
            set paths to {}
            repeat with chosenItem in chosen
                set end of paths to POSIX path of (chosenItem as alias)
            end repeat
            return paths
        end tell
        """)!
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            show("Finder 선택을 읽을 수 없습니다", "Finder 제어 요청을 허용해 주세요. 거절했다면 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → Famana에서 Finder를 켜 주세요.")
            return
        }
        guard result.numberOfItems > 0 else {
            show("파일을 선택해 주세요", "Finder에서 접두어를 붙일 파일 또는 폴더를 선택한 뒤 Enter를 누르세요. 여러 개도 가능합니다.")
            return
        }
        let items: [SelectedItem]
        do {
            items = try (1...result.numberOfItems).map { index in
                guard let path = result.atIndex(index)?.stringValue, !path.isEmpty else {
                    throw RenameFailure(message: "선택 항목의 경로를 읽을 수 없습니다.")
                }
                return try SelectedItem(URL(fileURLWithPath: path))
            }
        } catch { show("선택 항목을 읽을 수 없습니다", error.localizedDescription); return }
        originalName = items[0].url.lastPathComponent
        selectionCount = items.count
        let alert = NSAlert()
        alert.messageText = "선택한 \(items.count)개에 접두어 붙이기"
        alert.informativeText = "입력창에 포커스가 오면 받아쓰기가 자동으로 시작됩니다.\n말하거나 키보드로 입력하세요. 접두어 뒤에 공백 하나가 붙습니다."
        alert.addButton(withTitle: "붙이기")
        alert.addButton(withTitle: "취소")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 88))
        let field = PrefixField(frame: NSRect(x: 0, y: 50, width: 440, height: 28))
        field.placeholderString = "예: 여행, 업무, 확인완료"
        field.setAccessibilityLabel("파일 접두어")
        field.delegate = self
        let label = NSTextField(wrappingLabelWithString: originalName + (selectionCount > 1 ? " (외 \(selectionCount - 1)개)" : ""))
        label.frame = NSRect(x: 0, y: 0, width: 440, height: 40)
        label.textColor = .secondaryLabelColor
        view.addSubview(field)
        view.addSubview(label)
        alert.accessoryView = view
        input = field
        preview = label
        defer { input = nil; preview = nil }
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let plan = try renamePlan(items, prefix: field.stringValue)
                do { try applyRenames(plan) }
                catch { show("일괄 변경이 중단되었습니다", error.localizedDescription); return }
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?
                    .activate(options: [])
                return
            } catch { show("변경하지 못했습니다", error.localizedDescription) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let prefix = input?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        preview?.stringValue = (prefix.isEmpty ? originalName : prefix + " " + originalName)
            + (selectionCount > 1 ? " (외 \(selectionCount - 1)개도 같은 접두어)" : "")
    }
    func show(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
    @objc func permissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func dictationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
    }
    @objc func help() {
        show("Famana 사용 방법", "① 메뉴 막대의 F 아이콘을 클릭해 초록 점으로 전환\n② Finder에서 파일 한 개 또는 여러 개 선택 → Enter\n③ 입력창 포커스 시 자동 받아쓰기 → 결과 확인 → Enter\n\n영상 장면 저장: F 우클릭 → 캡처 저장 폴더 선택 → QuickTime에서 원하는 장면에 일시정지 → ⌘S\n원본 해상도 PNG로 저장하며, 첫 사용 시 QuickTime 제어를 허용해 주세요.\n편집한 영상은 먼저 Famana를 OFF로 바꾸고 QuickTime에서 저장하세요.\n\nEsc로 취소 · 다시 클릭하면 OFF\n받아쓰기는 시스템 설정 → 키보드에서 먼저 켜 주세요.")
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-icons" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for enabled in [false, true] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144, pixelsHigh: 144,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        statusIcon(enabled: enabled).draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: directory.appendingPathComponent(enabled ? "famana-on.png" : "famana-off.png"))
    }
} else if CommandLine.arguments.contains("--self-test") {
    do { try selfCheck() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    Task {
        do { try await frameCaptureCheck(); exit(0) }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
