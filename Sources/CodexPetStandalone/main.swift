import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import os
import QuartzCore
import Speech
import UniformTypeIdentifiers

private let appLogger = Logger(subsystem: "local.hal.codex-pet-standalone", category: "ui")

struct AIModelUsageStatus {
    let provider: String
    let remainingPercent: Double
    let isExhausted: Bool

    var displayText: String {
        if isExhausted {
            return "上限到達"
        }
        return "残り \(Int(remainingPercent.rounded()))%"
    }
}

fileprivate struct CodexUsageStatus {
    let remainingPercent: Double
    let resetAt: Date?
    let windowMinutes: Double?

    var isExhausted: Bool {
        remainingPercent <= 0.5 && resetAt.map { $0 > Date() } == true
    }

    var recoveryProgressPercent: Double? {
        guard isExhausted,
              let resetAt,
              let windowMinutes,
              windowMinutes > 0 else {
            return nil
        }
        let totalSeconds = windowMinutes * 60
        let remainingSeconds = max(0, resetAt.timeIntervalSinceNow)
        let elapsedSeconds = max(0, totalSeconds - remainingSeconds)
        return min(max((elapsedSeconds / totalSeconds) * 100, 0), 100)
    }

    var recoveryRemainingText: String? {
        guard isExhausted,
              let resetAt else {
            return nil
        }
        let seconds = max(0, Int(resetAt.timeIntervalSinceNow.rounded(.up)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "復帰まで \(hours)時間\(minutes)分"
        }
        return "復帰まで \(max(1, minutes))分"
    }
}

private enum CodexUsageReader {
    static func status() -> CodexUsageStatus? {
        let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        guard let latestFile = latestSessionFile(in: sessionsRoot),
              let tail = readTail(of: latestFile, maximumBytes: 1_048_576) else {
            return nil
        }

        for line in tail.components(separatedBy: .newlines).reversed() where line.contains("\"type\":\"token_count\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let now = Date().timeIntervalSince1970
            let windows = ["primary", "secondary"].compactMap { key -> (used: Double, resetAt: Date?, windowMinutes: Double?)? in
                guard let window = rateLimits[key] as? [String: Any],
                      let used = window["used_percent"] as? NSNumber else {
                    return nil
                }
                if let reset = window["resets_at"] as? NSNumber, reset.doubleValue <= now {
                    return (0, nil, nil)
                }
                let resetAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                let windowMinutes = (window["window_minutes"] as? NSNumber)?.doubleValue
                return (used.doubleValue, resetAt, windowMinutes)
            }
            guard let mostUsedWindow = windows.max(by: { $0.used < $1.used }) else {
                continue
            }
            return CodexUsageStatus(
                remainingPercent: min(max(100 - mostUsedWindow.used, 0), 100),
                resetAt: mostUsedWindow.resetAt,
                windowMinutes: mostUsedWindow.windowMinutes
            )
        }
        return nil
    }

    private static func latestSessionFile(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latestURL: URL?
        var latestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified > latestDate else {
                continue
            }
            latestDate = modified
            latestURL = url
        }
        return latestURL
    }

    private static func readTail(of url: URL, maximumBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else {
            return nil
        }
        let start = end > maximumBytes ? end - maximumBytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

final class SpriteSheet {
    let frames: [NSImage]
    let idleFrames: [NSImage]
    let runningFrames: [NSImage]
    let animationRows: [[NSImage]]
    let frameSize: CGSize

    init?(url: URL) {
        guard
            let sourceImage = NSImage(contentsOf: url),
            let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let layout = SpriteSheet.inferGrid(width: cgImage.width, height: cgImage.height)
        let frameWidth = cgImage.width / layout.columns
        let frameHeight = cgImage.height / layout.rows
        self.frameSize = CGSize(width: frameWidth, height: frameHeight)

        var rows: [[NSImage]] = []
        for row in 0..<layout.rows {
            var rowFrames: [NSImage] = []
            for column in 0..<layout.columns {
                let rect = CGRect(
                    x: column * frameWidth,
                    y: row * frameHeight,
                    width: frameWidth,
                    height: frameHeight
                )
                guard let cropped = cgImage.cropping(to: rect) else {
                    continue
                }
                guard SpriteSheet.hasVisiblePixels(cropped), let transparent = SpriteSheet.blackKeyedImage(cropped) else {
                    continue
                }
                rowFrames.append(NSImage(cgImage: transparent, size: CGSize(width: frameWidth, height: frameHeight)))
            }
            if !rowFrames.isEmpty {
                rows.append(rowFrames)
            }
        }

        let loadedFrames = rows.flatMap { $0 }
        guard !loadedFrames.isEmpty else {
            return nil
        }
        self.frames = loadedFrames
        self.animationRows = rows
        self.idleFrames = rows.first ?? loadedFrames
        self.runningFrames = SpriteSheet.bestRunningFrames(from: rows, fallback: loadedFrames)
    }

    private static func bestRunningFrames(from rows: [[NSImage]], fallback: [NSImage]) -> [NSImage] {
        let candidates = rows.dropFirst().filter { $0.count > 1 }
        return candidates.max { $0.count < $1.count } ?? fallback
    }

    private static func inferGrid(width: Int, height: Int) -> (columns: Int, rows: Int) {
        if width % 8 == 0, height % 9 == 0 {
            return (8, 9)
        }
        if width % 6 == 0, height % 6 == 0 {
            return (6, 6)
        }
        return (max(1, width / 192), max(1, height / 208))
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        guard let pixels = rgbaPixels(for: image) else {
            return true
        }
        var visibleCount = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            let alpha = pixels[index + 3]
            if alpha > 12, red > 18 || green > 18 || blue > 18 {
                visibleCount += 1
                if visibleCount > 500 {
                    return true
                }
            }
        }
        return false
    }

    private static func blackKeyedImage(_ image: CGImage) -> CGImage? {
        guard var pixels = rgbaPixels(for: image) else {
            return image
        }

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[index]
            let green = pixels[index + 1]
            let blue = pixels[index + 2]
            if red < 18, green < 18, blue < 18 {
                pixels[index + 3] = 0
            }
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func rgbaPixels(for image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}

@MainActor
protocol SpriteViewDelegate: AnyObject {
    func spriteViewDidClick(_ spriteView: SpriteView)
    func spriteViewDidDoubleClick(_ spriteView: SpriteView)
    func spriteViewDidRequestSettings(_ spriteView: SpriteView)
    func spriteViewDidRequestContextMenu(_ spriteView: SpriteView, event: NSEvent)
    func spriteViewDidStartMoving(_ spriteView: SpriteView)
    func spriteViewDidStopMoving(_ spriteView: SpriteView)
    func spriteView(_ spriteView: SpriteView, didDropFileURLs urls: [URL])
}

@MainActor
final class SpriteView: NSView {
    private enum AnimationMode {
        case idle
        case running
    }

    weak var delegate: SpriteViewDelegate?

    private var idleFrames: [NSImage] = []
    private var runningFrames: [NSImage] = []
    private var activeFrames: [NSImage] = []
    private var animationRows: [[NSImage]] = []
    private var animationMode: AnimationMode = .idle
    private var frameIndex = 0
    private var timer: Timer?
    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var didDrag = false
    private var notifiedMoveStart = false
    private let thinkingAnimationKey = "codexPet.thinking"
    private var usageStatus: CodexUsageStatus?
    private var modelUsageStatus: AIModelUsageStatus?
    private var isUsageHovered = false
    private var hoverTrackingArea: NSTrackingArea?
    private var pendingSingleClickTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isUsageHovered = true
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        isUsageHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isUsageHovered = false
        needsDisplay = true
    }

    func setModelUsageStatus(_ status: AIModelUsageStatus) {
        modelUsageStatus = status
        needsDisplay = true
    }

    func setSpriteSheet(_ sheet: SpriteSheet) {
        idleFrames = sheet.idleFrames
        runningFrames = sheet.runningFrames
        animationRows = sheet.animationRows
        activeFrames = idleFrames
        animationMode = .idle
        frameIndex = 0
        needsDisplay = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(timeInterval: PetAnimationConstants.frameInterval, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func advanceFrame() {
        guard activeFrames.count > 1 else {
            return
        }
        frameIndex = (frameIndex + 1) % activeFrames.count
        needsDisplay = true
    }

    private func setRunning(_ isRunning: Bool, direction: CGFloat = 1) {
        let nextMode: AnimationMode = isRunning ? .running : .idle
        guard nextMode != animationMode else {
            return
        }

        let directionalFrames: [NSImage]
        if isRunning, animationRows.count >= 3 {
            directionalFrames = direction < 0 ? animationRows[2] : animationRows[1]
        } else {
            directionalFrames = runningFrames
        }
        let nextFrames = isRunning ? directionalFrames : idleFrames
        guard !nextFrames.isEmpty else {
            return
        }
        animationMode = nextMode
        activeFrames = nextFrames
        frameIndex = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard !activeFrames.isEmpty else {
            return
        }
        let image = activeFrames[min(frameIndex, activeFrames.count - 1)]
        let imageArea = NSRect(
            x: bounds.minX,
            y: bounds.minY + 28,
            width: bounds.width,
            height: max(1, bounds.height - 28)
        )
        let target = aspectFitRect(
            aspectRatio: image.size,
            insideRect: imageArea.insetBy(dx: UIConstants.spriteViewInsets, dy: UIConstants.spriteViewInsets)
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1.0)
        drawUsageProgress()
        drawUsageLabelIfNeeded()
    }

    fileprivate func setUsageStatus(_ status: CodexUsageStatus?) {
        usageStatus = status
        if let status {
            if let recoveryText = status.recoveryRemainingText {
                toolTip = "Codex 使用量 0%・\(recoveryText)"
            } else {
                toolTip = "Codex 使用量残り \(Int(status.remainingPercent.rounded()))%"
            }
        } else {
            toolTip = "Codex 使用量を取得できません"
        }
        needsDisplay = true
    }

    private func drawUsageProgress() {
        let trackRect = NSRect(x: 8, y: 3, width: max(1, bounds.width - 16), height: 6)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3)
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        track.fill()

        let displayPercent: Double
        let isExhausted: Bool
        if let modelStatus = modelUsageStatus {
            displayPercent = modelStatus.remainingPercent
            isExhausted = modelStatus.isExhausted
        } else if let usageStatus = usageStatus {
            displayPercent = usageStatus.recoveryProgressPercent ?? usageStatus.remainingPercent
            isExhausted = usageStatus.isExhausted
        } else {
            return
        }

        let fillWidth = trackRect.width * CGFloat(displayPercent / 100)
        guard fillWidth > 0 else {
            return
        }
        let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillWidth, height: trackRect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
        let color: NSColor
        if isExhausted {
            color = .systemBlue
        } else if displayPercent > 50 {
            color = .systemGreen
        } else if displayPercent > 20 {
            color = .systemOrange
        } else {
            color = .systemRed
        }
        color.setFill()
        fill.fill()

        if isExhausted {
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: fillRect.minX, y: fillRect.minY))
            stripe.line(to: NSPoint(x: fillRect.maxX, y: fillRect.maxY))
            NSColor.white.withAlphaComponent(0.55).setStroke()
            stripe.lineWidth = 1
            stripe.stroke()
        }
    }

    private func drawUsageLabelIfNeeded() {
        guard isUsageHovered else {
            return
        }
        let text: String
        if let modelStatus = modelUsageStatus {
            text = "\(modelStatus.provider): \(modelStatus.displayText)"
        } else if let recoveryText = usageStatus?.recoveryRemainingText {
            text = "Codex: \(recoveryText)"
        } else if let usageStatus {
            text = "Codex: 残り \(Int(usageStatus.remainingPercent.rounded()))%"
        } else {
            text = "残量取得不可"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.midX - textSize.width / 2,
            y: 12,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    private func aspectFitRect(aspectRatio: CGSize, insideRect rect: CGRect) -> CGRect {
        guard aspectRatio.width > 0, aspectRatio.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let imageRatio = aspectRatio.width / aspectRatio.height
        let rectRatio = rect.width / rect.height
        var size = rect.size
        if imageRatio > rectRatio {
            size.height = rect.width / imageRatio
        } else {
            size.width = rect.height * imageRatio
        }

        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        didDrag = false
        notifiedMoveStart = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let dragStartScreenPoint,
            let dragStartWindowOrigin
        else {
            return
        }

        let currentPoint = NSEvent.mouseLocation
        let deltaX = currentPoint.x - dragStartScreenPoint.x
        let deltaY = currentPoint.y - dragStartScreenPoint.y
        if abs(deltaX) > 3 || abs(deltaY) > 3 {
            didDrag = true
            setRunning(true, direction: deltaX)
            if !notifiedMoveStart {
                notifiedMoveStart = true
                delegate?.spriteViewDidStartMoving(self)
            }
        }

        var frame = window.frame
        frame.origin = NSPoint(x: dragStartWindowOrigin.x + deltaX, y: dragStartWindowOrigin.y + deltaY)
        window.setFrame(frame, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        setRunning(false)
        if didDrag {
            delegate?.spriteViewDidStopMoving(self)
        }
        if !didDrag {
            if event.clickCount >= 2 {
                pendingSingleClickTimer?.invalidate()
                pendingSingleClickTimer = nil
                delegate?.spriteViewDidDoubleClick(self)
            } else {
                pendingSingleClickTimer?.invalidate()
                pendingSingleClickTimer = Timer.scheduledTimer(
                    withTimeInterval: NSEvent.doubleClickInterval,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.delegate?.spriteViewDidClick(self)
                        self.pendingSingleClickTimer = nil
                    }
                }
            }
        }
        dragStartScreenPoint = nil
        dragStartWindowOrigin = nil
        didDrag = false
        notifiedMoveStart = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return false
        }
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else {
            return false
        }
        delegate?.spriteView(self, didDropFileURLs: fileURLs)
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.spriteViewDidRequestContextMenu(self, event: event)
    }

    @objc private func startChatFromMenu() {
        delegate?.spriteViewDidClick(self)
    }

    @objc private func editSettingsFromMenu() {
        delegate?.spriteViewDidRequestSettings(self)
    }

    func playAnimation(row: Int, duration: TimeInterval = 2.5) {
        guard animationRows.indices.contains(row), !animationRows[row].isEmpty else {
            return
        }
        timer?.invalidate()
        activeFrames = animationRows[row]
        frameIndex = 0
        timer = Timer.scheduledTimer(timeInterval: PetAnimationConstants.animationFrameInterval, target: self, selector: #selector(advanceFrame), userInfo: nil, repeats: true)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.activeFrames = self.idleFrames
                self.frameIndex = 0
            }
        }
    }

    func setThinking(_ thinking: Bool) {
        guard let layer else {
            return
        }
        if thinking {
            guard layer.animation(forKey: thinkingAnimationKey) == nil else {
                return
            }
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            bounce.values = [0, 0, 8, 0, -3, 0]
            bounce.keyTimes = [0, 0.15, 0.4, 0.65, 0.82, 1]
            bounce.duration = PetAnimationConstants.thinkingAnimationDuration
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bounce, forKey: thinkingAnimationKey)
        } else {
            layer.removeAnimation(forKey: thinkingAnimationKey)
        }
    }
}

@MainActor
final class BubbleView: NSView {
    private enum TurnRole {
        case query
        case response
    }

    private struct ConversationTurn {
        let role: TurnRole
        let text: String
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let resizeHandleSize: CGFloat = 16
    private var isResizing = false
    private var resizeStartLocation: NSPoint = .zero
    private var resizeStartSize: NSSize = .zero
    private var clipboardText = ""
    private var turns: [ConversationTurn] = []
    private var currentFontSize: CGFloat = UIConstants.bubbleTextFontSize

    var resizeHandler: ((NSSize) -> Void)?
    var closeHandler: (() -> Void)?

    func appendTurn(query: String?, response: String) {
        if let query, !query.isEmpty {
            turns.append(ConversationTurn(role: .query, text: query))
        }
        turns.append(ConversationTurn(role: .response, text: response))
        turns = Array(turns.suffix(UIConstants.bubbleHistoryMaxTurns))
        clipboardText = turns
            .map { turn in "\(turn.role == .query ? "あなた" : "返答"): \(turn.text)" }
            .joined(separator: "\n\n")
        renderTurns()
    }

    func clearHistory() {
        turns = []
        renderTurns()
    }

    private func renderTurns() {
        let result = NSMutableAttributedString()
        let labelFont = NSFont.systemFont(ofSize: currentFontSize, weight: .bold)
        let textFont = NSFont.systemFont(ofSize: currentFontSize, weight: .medium)
        for (index, turn) in turns.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            let color = turn.role == .query ? UIConstants.bubbleQueryTextColor : UIConstants.bubbleResponseTextColor
            let label = turn.role == .query ? "あなた: " : "🐾 "
            result.append(NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: color]))
            result.append(NSAttributedString(string: turn.text, attributes: [.font: textFont, .foregroundColor: color]))
        }
        textView.textStorage?.setAttributedString(result)
        textView.scrollToEndOfDocument(nil)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.font = .systemFont(ofSize: currentFontSize, weight: .medium)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.isBordered = false
        copyButton.bezelStyle = .circular
        copyButton.image = NSImage(
            systemSymbolName: "doc.on.doc.fill",
            accessibilityDescription: "通知文をコピー"
        )
        copyButton.imagePosition = .imageOnly
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "通知文をクリップボードへコピー"
        copyButton.target = self
        copyButton.action = #selector(copyNotification)
        addSubview(copyButton)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .circular
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "閉じる"
        )
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closeBubble)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -54),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        ])
        NSLayoutConstraint.activate([
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            copyButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22)
        ])
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        closeButton.layer?.cornerRadius = 11
    }

    func preferredHeight(for message: String, width: CGFloat, minimumLines: Int = 3) -> CGFloat {
        let usableWidth = max(1, width - 20)
        let font = NSFont.systemFont(ofSize: currentFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (message as NSString).boundingRect(
            with: NSSize(width: usableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let minimumTextHeight = lineHeight * CGFloat(max(minimumLines, 1))
        let textHeight = ceil(max(rect.height, minimumTextHeight))
        return ceil(textHeight + 20)
    }

    func preferredWidth(for message: String, maximumWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: currentFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let longestLineWidth = message
            .components(separatedBy: .newlines)
            .map {
                ceil(
                    ($0 as NSString).boundingRect(
                        with: NSSize(
                            width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                        attributes: attributes
                    ).width
                )
            }
            .max() ?? 0
        let horizontalInsetsAndButtons: CGFloat = 69
        return min(max(20, longestLineWidth + horizontalInsetsAndButtons), maximumWidth)
    }

    func setFontSize(_ size: CGFloat) {
        currentFontSize = size
        textView.font = .systemFont(ofSize: size, weight: .medium)
        renderTurns()
        needsDisplay = true
        needsLayout = true
    }

    static func formattedNotificationText(_ message: String) -> String {
        let messageWithoutTrailingWhitespace = message
            .components(separatedBy: .newlines)
            .map { line -> String in
                var trimmedLine = line
                while trimmedLine.last?.isWhitespace == true {
                    trimmedLine.removeLast()
                }
                return trimmedLine
            }
            .joined(separator: "\n")

        var result = ""
        var visibleCharacterCount = 0

        for character in messageWithoutTrailingWhitespace {
            if character.isNewline {
                result.append(character)
                visibleCharacterCount = 0
                continue
            }

            let ignoresForWidth = character.isWhitespace
            if !ignoresForWidth, visibleCharacterCount >= NotificationConstants.preferredCharactersPerLine {
                result.append("\n")
                visibleCharacterCount = 0
            }

            result.append(character)
            if !ignoresForWidth {
                visibleCharacterCount += 1
            }
        }

        return result
    }

    @objc private func closeBubble() {
        closeHandler?()
    }

    @objc private func copyNotification() {
        guard !clipboardText.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let bubbleRect = bounds.insetBy(dx: UIConstants.bubbleViewInsets.left, dy: UIConstants.bubbleViewInsets.top)
        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: UIConstants.bubbleCornerRadius, yRadius: UIConstants.bubbleCornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bounds.midX - 8, y: 9))
        tail.line(to: NSPoint(x: bounds.midX + 10, y: 9))
        tail.line(to: NSPoint(x: bounds.midX, y: 0))
        tail.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        tail.fill()

        drawResizeHandle()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(resizeHandleRect(), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard resizeHandleRect().contains(location) else {
            super.mouseDown(with: event)
            return
        }
        isResizing = true
        resizeStartLocation = event.locationInWindow
        resizeStartSize = bounds.size
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing else {
            super.mouseDragged(with: event)
            return
        }
        let deltaX = event.locationInWindow.x - resizeStartLocation.x
        let deltaY = event.locationInWindow.y - resizeStartLocation.y
        let minWidth: CGFloat = 20
        let minHeight: CGFloat = 80
        let newWidth = max(minWidth, resizeStartSize.width + deltaX)
        let newHeight = max(minHeight, resizeStartSize.height + deltaY)
        resizeHandler?(NSSize(width: newWidth, height: newHeight))
    }

    override func mouseUp(with event: NSEvent) {
        isResizing = false
        super.mouseUp(with: event)
    }

    private func resizeHandleRect() -> NSRect {
        NSRect(
            x: bounds.maxX - UIConstants.bubbleResizeHandleSize - 8,
            y: bounds.minY + 10,
            width: UIConstants.bubbleResizeHandleSize,
            height: UIConstants.bubbleResizeHandleSize
        )
    }

    private func drawResizeHandle() {
        let handleRect = resizeHandleRect()
        let path = NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3)
        NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 1
        path.stroke()

        let grip = NSBezierPath()
        grip.lineWidth = 1.1
        let baseX = handleRect.maxX - 11
        let baseY = handleRect.minY + 3
        for offset in stride(from: CGFloat(0), through: 8, by: 4) {
            grip.move(to: NSPoint(x: baseX + offset, y: baseY))
            grip.line(to: NSPoint(x: baseX + 8, y: baseY + offset))
        }
        NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
        grip.stroke()
    }
}

@MainActor
final class KeyablePetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ComposerTextView: NSTextView {
    var sendHandler: (() -> Void)?
    var didChangeBlock: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        sendHandler?()
    }

    override func insertLineBreak(_ sender: Any?) {
        textStorage?.replaceCharacters(in: selectedRange(), with: "\n")
    }

    override func didChangeText() {
        super.didChangeText()
        didChangeBlock?()
    }
}

@MainActor
final class ComposerBubbleView: NSView {
    private let modelLabel = NSTextField(labelWithString: "")
    private let inputScrollView = NSScrollView()
    private let inputTextView = ComposerTextView()
    private let voiceButton = NSButton()
    private let sendButton = NSButton()
    private var inputScrollViewHeightConstraint: NSLayoutConstraint?

    var sendHandler: ((String) -> Void)?
    var voiceHandler: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        modelLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.lineBreakMode = .byTruncatingTail

        inputTextView.isRichText = false
        inputTextView.isEditable = true
        inputTextView.isSelectable = true
        inputTextView.isVerticallyResizable = true
        inputTextView.isHorizontallyResizable = false
        inputTextView.drawsBackground = false
        inputTextView.font = .systemFont(ofSize: UIConstants.composerTextFontSize)
        inputTextView.textColor = .labelColor
        inputTextView.textContainerInset = NSSize(width: 6, height: 6)
        inputTextView.textContainer?.widthTracksTextView = true
        inputTextView.textContainer?.lineFragmentPadding = 0
        inputTextView.sendHandler = { [weak self] in
            self?.send()
        }
        inputTextView.didChangeBlock = { [weak self] in
            self?.updateInputHeight()
        }

        inputScrollView.hasVerticalScroller = true
        inputScrollView.borderType = .bezelBorder
        inputScrollView.documentView = inputTextView

        voiceButton.title = "🎙"
        voiceButton.toolTip = "音声入力"
        voiceButton.bezelStyle = .rounded
        voiceButton.target = self
        voiceButton.action = #selector(startVoiceInput)

        sendButton.title = "送信"
        sendButton.toolTip = "AIへ送信"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)

        let buttonStack = NSStackView(views: [voiceButton, sendButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6
        voiceButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        sendButton.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let stack = NSStackView(views: [modelLabel, inputScrollView, buttonStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        addSubview(stack)

        inputScrollViewHeightConstraint = inputScrollView.heightAnchor.constraint(equalToConstant: 78)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            inputScrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            inputScrollViewHeightConstraint!,
            buttonStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(modelName: String) {
        modelLabel.stringValue = "モデル: \(modelName)"
    }

    func focusInput() {
        window?.makeFirstResponder(inputTextView)
    }

    func setInput(_ text: String) {
        inputTextView.string = text
        focusInput()
    }

    func setBusy(_ busy: Bool) {
        sendButton.isEnabled = !busy
        voiceButton.isEnabled = !busy
        inputTextView.isEditable = !busy
        inputTextView.isSelectable = !busy
        sendButton.title = busy ? "送信中" : "送信"
    }

    @objc private func send() {
        let text = inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        inputTextView.string = ""
        sendHandler?(text)
    }

    @objc private func startVoiceInput() {
        voiceHandler?()
    }

    private func updateInputHeight() {
        let maxHeight: CGFloat = 300
        let minHeight: CGFloat = 78

        let textSize = inputTextView.attributedString().size()
        let requiredHeight = min(max(textSize.height + 12, minHeight), maxHeight)
        inputScrollViewHeightConstraint?.constant = requiredHeight
        window?.layoutIfNeeded()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        let bubbleRect = bounds.insetBy(dx: UIConstants.composerViewInsets.left, dy: UIConstants.composerViewInsets.top)
        let path = NSBezierPath(roundedRect: bubbleRect, xRadius: UIConstants.composerCornerRadius, yRadius: UIConstants.composerCornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
        path.lineWidth = UIConstants.composerBorderWidth
        path.stroke()

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bounds.midX - 9, y: bounds.maxY - 9))
        tail.line(to: NSPoint(x: bounds.midX + 9, y: bounds.maxY - 9))
        tail.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        tail.close()
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        tail.fill()
    }
}

@MainActor
final class VoiceController: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: VoiceConstants.defaultLanguage))
    private var isListening = false
    private var voiceIdentifier = ""

    var availableVoiceIDs: [String] {
        AVSpeechSynthesisVoice.speechVoices().map(\.identifier)
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func configure(voiceIdentifier: String) {
        self.voiceIdentifier = voiceIdentifier
    }

    func displayName(for voiceID: String) -> String {
        AVSpeechSynthesisVoice(identifier: voiceID)?.name ?? voiceID
    }

    func speak(_ text: String, enabled: Bool) {
        guard enabled else {
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func stopListening() {
        guard isListening else {
            return
        }
        recognitionTask?.cancel()
        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.reset()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
    }

    func startListening(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        guard !isListening else {
            stopListening()
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else {
                    return
                }
                guard status == .authorized else {
                    onError("音声認識が許可されていません。システム設定で音声認識を許可してください。")
                    return
                }
                guard let speechRecognizer = self.speechRecognizer, speechRecognizer.isAvailable else {
                    onError("このMacでは音声認識を開始できませんでした。")
                    return
                }
                self.beginAudioRecognition(speechRecognizer: speechRecognizer, onResult: onResult, onError: onError)
            }
        }
    }

    private func beginAudioRecognition(
        speechRecognizer: SFSpeechRecognizer,
        onResult: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: VoiceConstants.audioBufferSize, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            inputNode.removeTap(onBus: 0)
            onError("マイク入力を開始できませんでした: \(error.localizedDescription)")
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    self?.stopListening()
                    onResult(text)
                } else if let error {
                    self?.stopListening()
                    onError("聞き取りに失敗しました: \(error.localizedDescription)")
                }
            }
        }
    }
}

struct KeyboardShortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ rawValue: String) {
        let parts = rawValue
            .lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let key = parts.last else {
            return nil
        }

        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "opt", "option", "alt":
                modifiers.insert(.option)
            case "ctrl", "control":
                modifiers.insert(.control)
            default:
                break
            }
        }

        self.key = key
        self.modifiers = modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        let pressed = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return pressed == modifiers && event.charactersIgnoringModifiers?.lowercased() == key
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let pets: [Pet]
    private var settings: PetSettings
    private var messages: [String]
    private let onSave: (PetSettings) -> Void
    private let onPetGenerated: (String) -> Void
    private let assetGenerator = PetAssetGenerator()
    private var generatedPetID: String?

    private let petPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let customSizeField = NSTextField()
    private let chatCommandField = NSTextField()
    private let notificationTextField = NSTextField()
    private let notificationFileField = NSTextField()
    private let notificationDurationField = NSTextField()
    private let notificationWidthField = NSTextField()
    private let notificationHeightField = NSTextField()
    private let notificationFontSizeField = NSTextField()
    private let inputBubbleWidthField = NSTextField()
    private let chatLogDirectoryField = NSTextField()
    private let dotenvPathField = NSTextField()
    private let idleCheckbox = NSButton(checkboxWithTitle: "日常会話を有効にする", target: nil, action: nil)
    private let idleDelayField = NSTextField()
    private let voiceInputCheckbox = NSButton(checkboxWithTitle: "音声入力", target: nil, action: nil)
    private let voiceOutputCheckbox = NSButton(checkboxWithTitle: "音声出力", target: nil, action: nil)
    private let voicePopup = NSPopUpButton()
    private let voiceShortcutField = NSTextField()
    private let aiProviderPopup = NSPopUpButton()
    private let aiEndpointField = NSTextField()
    private let sakanaModelStack = NSStackView()
    private let sakanaModelButtonsStack = NSStackView()
    private let ollamaModelStack = NSStackView()
    private let ollamaModelButtonsStack = NSStackView()
    private let refreshOllamaModelsButton = NSButton(title: "更新", target: nil, action: nil)
    private let aiSystemPromptField = NSTextView()
    private let ragFilesTableView = NSTableView()
    private let ragFilesScrollView = NSScrollView()
    private let ragFilesSummaryLabel = NSTextField(labelWithString: "")
    private let addRAGFileButton = NSButton(title: "追加…", target: nil, action: nil)
    private let removeRAGFileButton = NSButton(title: "削除", target: nil, action: nil)
    private let ollamaSectionStack = NSStackView()
    private let ollamaDisclosureButton = NSButton()
    private let ollamaHeaderStack = NSStackView()
    private let ollamaContentStack = NSStackView()
    private var sakanaModelButtons: [NSButton] = []
    private var ollamaModelButtons: [NSButton] = []
    private var ollamaModelCandidates: [String] = []
    private var ollamaSectionExpanded = false
    private var ragFilePaths: [String] = []

    init(
        pets: [Pet],
        settings: PetSettings,
        onPetGenerated: @escaping (String) -> Void,
        onSave: @escaping (PetSettings) -> Void
    ) {
        self.pets = pets
        self.settings = settings
        self.messages = settings.idleConversationMessages
        self.onPetGenerated = onPetGenerated
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UIConstants.settingsWindowWidth, height: UIConstants.settingsWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Pet Settings"
        window.minSize = NSSize(width: UIConstants.settingsWindowMinWidth, height: UIConstants.settingsWindowMinHeight)
        super.init(window: window)
        buildContent()
        loadSettingsIntoControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func syncDisplayedSettings(_ settings: PetSettings) {
        self.settings = settings
        self.messages = settings.idleConversationMessages
        self.ragFilePaths = settings.ragFilePaths
        loadSettingsIntoControls()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        contentView.addSubview(scrollView)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        scrollView.documentView = stack

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        stack.addArrangedSubview(sectionTitle("基本設定"))
        stack.addArrangedSubview(row(label: "ペットの種類", control: petPopup))
        sizePopup.target = self
        sizePopup.action = #selector(sizePopupChanged)
        stack.addArrangedSubview(row(label: "大きさ", control: sizePopup))
        stack.addArrangedSubview(row(label: "カスタムサイズ", control: customSizeField))
        stack.addArrangedSubview(row(label: "チャット起動コマンド", control: chatCommandField))
        stack.addArrangedSubview(row(label: "通知テキスト", control: notificationTextField))
        stack.addArrangedSubview(helpText("そのまま吹き出しに出します。"))
        stack.addArrangedSubview(pathRow(label: "通知ファイル", control: notificationFileField, buttonTitle: "選択…", action: #selector(chooseNotificationFile)))
        stack.addArrangedSubview(helpText("通知テキストの代わりに使います。"))
        stack.addArrangedSubview(row(label: "通知表示時間（秒）", control: notificationDurationField))
        stack.addArrangedSubview(row(label: "通知枠の横幅", control: notificationWidthField))
        stack.addArrangedSubview(row(label: "通知枠の高さ", control: notificationHeightField))
        stack.addArrangedSubview(helpText("上側の吹き出しサイズです。"))
        stack.addArrangedSubview(row(label: "通知枠フォント", control: notificationFontSizeField))
        stack.addArrangedSubview(helpText("基本は 16pt です。"))
        stack.addArrangedSubview(row(label: "入力枠の横幅", control: inputBubbleWidthField))
        stack.addArrangedSubview(helpText("下側の吹き出し幅です。"))
        stack.addArrangedSubview(pathRow(label: "ログ保存先", control: chatLogDirectoryField, buttonTitle: "選択…", action: #selector(chooseLogDirectory)))
        stack.addArrangedSubview(helpText("会話ログの保存先です。"))
        stack.addArrangedSubview(sectionTitle("RAG"))
        stack.addArrangedSubview(helpText("参照したいファイルを登録します。"))
        ragFilesScrollView.translatesAutoresizingMaskIntoConstraints = false
        ragFilesScrollView.hasVerticalScroller = true
        ragFilesScrollView.borderType = .bezelBorder
        ragFilesTableView.headerView = nil
        ragFilesTableView.usesAlternatingRowBackgroundColors = true
        ragFilesTableView.delegate = self
        ragFilesTableView.dataSource = self
        ragFilesTableView.allowsMultipleSelection = true
        let ragColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ragFile"))
        ragColumn.title = "RAGファイル"
        ragColumn.resizingMask = .autoresizingMask
        ragFilesTableView.addTableColumn(ragColumn)
        ragFilesScrollView.documentView = ragFilesTableView
        ragFilesScrollView.heightAnchor.constraint(equalToConstant: UIConstants.ragTableViewHeight).isActive = true
        stack.addArrangedSubview(ragFilesScrollView)
        ragFilesSummaryLabel.font = .systemFont(ofSize: 11)
        ragFilesSummaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(ragFilesSummaryLabel)
        let ragButtons = NSStackView(views: [addRAGFileButton, removeRAGFileButton])
        ragButtons.orientation = .horizontal
        ragButtons.spacing = 8
        stack.addArrangedSubview(ragButtons)

        stack.addArrangedSubview(button("画像をアップロードしてペットを作成…", action: #selector(generatePetFromImage)))

        stack.addArrangedSubview(sectionTitle("会話AI"))
        stack.addArrangedSubview(row(label: "モデル", control: aiProviderPopup))
        sakanaModelStack.translatesAutoresizingMaskIntoConstraints = false
        sakanaModelStack.orientation = .vertical
        sakanaModelStack.alignment = .leading
        sakanaModelStack.spacing = 8
        sakanaModelStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        sakanaModelStack.wantsLayer = true
        sakanaModelStack.layer?.cornerRadius = 10
        sakanaModelStack.layer?.borderWidth = 1
        sakanaModelStack.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        sakanaModelStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sakanaModelStack.layer?.masksToBounds = true
        sakanaModelStack.addArrangedSubview(helpText("内部 LLM を 1 つ選びます。"))
        sakanaModelButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        sakanaModelButtonsStack.orientation = .vertical
        sakanaModelButtonsStack.alignment = .leading
        sakanaModelButtonsStack.spacing = 6
        sakanaModelButtonsStack.detachesHiddenViews = true
        sakanaModelStack.addArrangedSubview(sakanaModelButtonsStack)
        sakanaModelStack.isHidden = true
        stack.addArrangedSubview(sakanaModelStack)

        stack.addArrangedSubview(multilineRow(label: "ペットの性格", textView: aiSystemPromptField))
        stack.addArrangedSubview(helpText("日常会話の話題、言葉遣い、語尾、感情表現にも反映します。"))

        stack.addArrangedSubview(sectionTitle("日常会話"))
        idleCheckbox.target = self
        idleCheckbox.action = #selector(toggleSettingCheckbox)
        stack.addArrangedSubview(idleCheckbox)
        stack.addArrangedSubview(row(label: "開始までの秒数", control: idleDelayField))

        stack.addArrangedSubview(sectionTitle("音声"))
        voiceInputCheckbox.target = self
        voiceInputCheckbox.action = #selector(toggleSettingCheckbox)
        stack.addArrangedSubview(voiceInputCheckbox)
        voiceOutputCheckbox.target = self
        voiceOutputCheckbox.action = #selector(toggleSettingCheckbox)
        stack.addArrangedSubview(voiceOutputCheckbox)
        stack.addArrangedSubview(row(label: "声の種類", control: voicePopup))
        stack.addArrangedSubview(row(label: "ON/OFFショートカット", control: voiceShortcutField))

        ollamaSectionStack.translatesAutoresizingMaskIntoConstraints = false
        ollamaSectionStack.orientation = .vertical
        ollamaSectionStack.alignment = .leading
        ollamaSectionStack.spacing = 8
        ollamaSectionStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        ollamaSectionStack.detachesHiddenViews = true

        ollamaHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        ollamaHeaderStack.orientation = .horizontal
        ollamaHeaderStack.alignment = .centerY
        ollamaHeaderStack.spacing = 8
        ollamaDisclosureButton.bezelStyle = .inline
        ollamaDisclosureButton.setButtonType(.momentaryChange)
        ollamaDisclosureButton.target = self
        ollamaDisclosureButton.action = #selector(toggleOllamaSection)
        ollamaDisclosureButton.attributedTitle = NSAttributedString(string: "Ollama")
        ollamaDisclosureButton.toolTip = "クリックで展開/折りたたみ"
        ollamaHeaderStack.addArrangedSubview(ollamaDisclosureButton)
        let ollamaHeaderSpacer = NSView()
        ollamaHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        ollamaHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        ollamaHeaderSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ollamaHeaderStack.addArrangedSubview(ollamaHeaderSpacer)

        ollamaContentStack.translatesAutoresizingMaskIntoConstraints = false
        ollamaContentStack.orientation = .vertical
        ollamaContentStack.alignment = .leading
        ollamaContentStack.spacing = 10
        ollamaContentStack.detachesHiddenViews = true
        ollamaContentStack.addArrangedSubview(helpText("Ollama 選択時だけ表示します。"))
        ollamaContentStack.addArrangedSubview(row(label: "接続先URL", control: aiEndpointField))
        ollamaContentStack.addArrangedSubview(helpText("通常は localhost の `/v1/chat/completions` です。"))
        ollamaModelStack.translatesAutoresizingMaskIntoConstraints = false
        ollamaModelStack.orientation = .vertical
        ollamaModelStack.alignment = .leading
        ollamaModelStack.spacing = 8
        ollamaModelStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        ollamaModelStack.wantsLayer = true
        ollamaModelStack.layer?.cornerRadius = 10
        ollamaModelStack.layer?.borderWidth = 1
        ollamaModelStack.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        ollamaModelStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        ollamaModelStack.layer?.masksToBounds = true
        ollamaModelStack.addArrangedSubview(helpText("`ollama list` の候補を読み込みます。"))
        ollamaModelButtonsStack.translatesAutoresizingMaskIntoConstraints = false
        ollamaModelButtonsStack.orientation = .vertical
        ollamaModelButtonsStack.alignment = .leading
        ollamaModelButtonsStack.spacing = 6
        ollamaModelButtonsStack.detachesHiddenViews = true
        ollamaModelStack.addArrangedSubview(ollamaModelButtonsStack)
        let ollamaModelButtonRow = NSStackView(views: [refreshOllamaModelsButton])
        ollamaModelButtonRow.orientation = .horizontal
        ollamaModelButtonRow.alignment = .centerY
        ollamaModelButtonRow.spacing = 8
        ollamaModelStack.addArrangedSubview(ollamaModelButtonRow)
        ollamaContentStack.addArrangedSubview(pathRow(label: ".envファイル", control: dotenvPathField, buttonTitle: "選択…", action: #selector(chooseDotenvFile)))
        let envHint = NSTextField(labelWithString: ".env に APIキーを置きます。")
        envHint.maximumNumberOfLines = 0
        envHint.lineBreakMode = .byWordWrapping
        envHint.translatesAutoresizingMaskIntoConstraints = false
        envHint.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        ollamaContentStack.addArrangedSubview(ollamaModelStack)
        ollamaContentStack.addArrangedSubview(envHint)

        ollamaSectionStack.addArrangedSubview(ollamaHeaderStack)
        ollamaSectionStack.addArrangedSubview(ollamaContentStack)
        ollamaSectionStack.wantsLayer = true
        ollamaSectionStack.layer?.cornerRadius = 12
        ollamaSectionStack.layer?.borderWidth = 1
        ollamaSectionStack.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        ollamaSectionStack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        ollamaSectionStack.layer?.masksToBounds = true
        ollamaSectionStack.isHidden = true
        stack.addArrangedSubview(ollamaSectionStack)

        let footerButtons = NSStackView()
        footerButtons.orientation = .horizontal
        footerButtons.spacing = 8
        footerButtons.addArrangedSubview(button("保存", action: #selector(saveSettings)))
        footerButtons.addArrangedSubview(button("閉じる", action: #selector(closeWindow)))
        stack.addArrangedSubview(footerButtons)
    }

    private func loadSettingsIntoControls() {
        petPopup.removeAllItems()
        for pet in pets {
            petPopup.addItem(withTitle: pet.manifest.displayName)
            petPopup.lastItem?.representedObject = pet.manifest.id
        }
        if let index = pets.firstIndex(where: { $0.manifest.id == settings.preferredPetID }) {
            petPopup.selectItem(at: index)
        }

        sizePopup.removeAllItems()
        for size in [128, 168, 224, 288] {
            sizePopup.addItem(withTitle: "\(size)")
            sizePopup.lastItem?.representedObject = Double(size)
        }
        if let item = sizePopup.itemArray.first(where: { ($0.representedObject as? Double) == settings.size }) {
            sizePopup.select(item)
        }

        customSizeField.stringValue = "\(Int(settings.size))"
        customSizeField.delegate = self
        chatCommandField.stringValue = settings.chatCommand.joined(separator: " ")
        chatCommandField.delegate = self
        notificationTextField.stringValue = settings.notificationText
        notificationTextField.delegate = self
        notificationFileField.stringValue = settings.notificationFile
        notificationFileField.delegate = self
        notificationDurationField.stringValue = "\(Int(settings.notificationDurationSeconds))"
        notificationDurationField.delegate = self
        notificationWidthField.stringValue = "\(Int(settings.notificationWidth))"
        notificationWidthField.delegate = self
        notificationHeightField.stringValue = "\(Int(settings.notificationHeight))"
        notificationHeightField.delegate = self
        notificationFontSizeField.stringValue = "\(Int(settings.notificationFontSize))"
        notificationFontSizeField.delegate = self
        inputBubbleWidthField.stringValue = "\(Int(settings.inputBubbleWidth))"
        inputBubbleWidthField.delegate = self
        chatLogDirectoryField.stringValue = settings.chatLogDirectoryPath
        chatLogDirectoryField.delegate = self
        idleCheckbox.state = settings.idleConversationEnabled ? .on : .off
        idleDelayField.stringValue = "\(Int(settings.idleConversationDelaySeconds))"
        idleDelayField.delegate = self
        voiceInputCheckbox.state = settings.voiceInputEnabled ? .on : .off
        voiceOutputCheckbox.state = settings.voiceOutputEnabled ? .on : .off
        voiceShortcutField.stringValue = settings.voiceToggleShortcut
        voiceShortcutField.delegate = self
        aiProviderPopup.removeAllItems()
        aiProviderPopup.addItems(withTitles: SettingsConstants.supportedAIProviders)
        for (index, provider) in SettingsConstants.supportedAIProviders.enumerated() {
            aiProviderPopup.item(at: index)?.representedObject = provider
        }
        aiProviderPopup.target = self
        aiProviderPopup.action = #selector(aiProviderChanged)
        if let item = aiProviderPopup.itemArray.first(where: { ($0.representedObject as? String) == settings.aiProvider }) {
            aiProviderPopup.select(item)
        }
        aiEndpointField.stringValue = settings.aiEndpoint
        aiEndpointField.delegate = self
        refreshOllamaModelsButton.target = self
        refreshOllamaModelsButton.action = #selector(refreshOllamaModels)
        dotenvPathField.stringValue = settings.dotenvFilePath
        dotenvPathField.delegate = self
        aiSystemPromptField.string = settings.aiSystemPrompt
        ragFilePaths = settings.ragFilePaths
        addRAGFileButton.target = self
        addRAGFileButton.action = #selector(addRAGFiles)
        removeRAGFileButton.target = self
        removeRAGFileButton.action = #selector(removeSelectedRAGFiles)
        voicePopup.removeAllItems()
        for voice in AVSpeechSynthesisVoice.speechVoices().sorted(by: { $0.name < $1.name }) {
            voicePopup.addItem(withTitle: "\(voice.name) (\(voice.language))")
            voicePopup.lastItem?.representedObject = voice.identifier
        }
        if let item = voicePopup.itemArray.first(where: { ($0.representedObject as? String) == settings.voiceIdentifier }) {
            voicePopup.select(item)
        }
        rebuildSakanaModelButtons(selectedModel: settings.aiModel)
        refreshOllamaModelCandidates(selectedModel: settings.aiModel)
        ragFilesTableView.reloadData()
        updateRAGSummary()
        updateOllamaModelUI()
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: UIConstants.sectionTitleFontSize, weight: .semibold)
        return label
    }

    private func row(label title: String, control: NSControl) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: UIConstants.labelWidth).isActive = true
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: UIConstants.controlMinWidth).isActive = true

        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func helpText(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: UIConstants.helpTextFontSize)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: UIConstants.controlMinWidth).isActive = true
        return label
    }

    private func updateRAGSummary() {
        if ragFilePaths.isEmpty {
            ragFilesSummaryLabel.stringValue = "RAGファイルは未登録です。"
        } else {
            ragFilesSummaryLabel.stringValue = "\(ragFilePaths.count) 件の RAGファイルが登録されています。"
        }
    }

    private func pathRow(label title: String, control: NSTextField, buttonTitle: String, action: Selector) -> NSStackView {
        let browseButton = NSButton(title: buttonTitle, target: self, action: action)
        browseButton.bezelStyle = .rounded
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: UIConstants.controlMinWidth).isActive = true
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: UIConstants.labelWidth).isActive = true

        let controlStack = NSStackView(views: [control, browseButton])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 8

        let stack = NSStackView(views: [label, controlStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func comboRow(label title: String, control: NSComboBox, buttonTitle: String, action: Selector) -> NSStackView {
        let browseButton = NSButton(title: buttonTitle, target: self, action: action)
        browseButton.bezelStyle = .rounded
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: UIConstants.controlMinWidth).isActive = true
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: UIConstants.labelWidth).isActive = true

        let controlStack = NSStackView(views: [control, browseButton])
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 8

        let stack = NSStackView(views: [label, controlStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        return stack
    }

    private func checkboxRow(title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = .off
        button.setButtonType(.switch)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.controlSize = .regular
        return button
    }

    private func rebuildCheckboxOptions(
        into buttonsStack: NSStackView,
        buttons: inout [NSButton],
        options: [String],
        selectedValue: String?,
        action: Selector
    ) {
        for button in buttons {
            buttonsStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll()

        let normalizedSelected = selectedValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for option in options {
            let button = checkboxRow(title: option, action: action)
            button.state = option == normalizedSelected ? .on : .off
            buttons.append(button)
            buttonsStack.addArrangedSubview(button)
        }
        if buttons.allSatisfy({ $0.state != .on }), let first = buttons.first {
            first.state = .on
        }
    }

    private func selectedCheckboxValue(from buttons: [NSButton], fallback: String) -> String {
        buttons.first(where: { $0.state == .on })?.title ?? fallback
    }

    private func ensureExclusiveSelection(in buttons: [NSButton], selected sender: NSButton) {
        for button in buttons {
            button.state = (button == sender) ? .on : .off
        }
    }

    private func multilineRow(label title: String, textView: NSTextView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: UIConstants.labelWidth).isActive = true

        textView.isRichText = false
        textView.font = .systemFont(ofSize: UIConstants.composerTextFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: UIConstants.controlMinWidth).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let stack = NSStackView(views: [label, scrollView])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        return stack
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === ragFilesTableView {
            return ragFilePaths.count
        }
        return messages.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === ragFilesTableView {
            let field = NSTextField(labelWithString: ragFilePaths[row])
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = ragFilePaths[row]
            return field
        }
        let field = NSTextField()
        field.stringValue = messages[row]
        field.isBordered = false
        field.backgroundColor = .clear
        field.isEditable = true
        field.delegate = self
        field.tag = row
        return field
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }
        if field === notificationTextField ||
            field === notificationFileField ||
            field === notificationDurationField ||
            field === notificationWidthField ||
            field === notificationHeightField ||
            field === notificationFontSizeField ||
            field === inputBubbleWidthField ||
            field === chatLogDirectoryField ||
            field === dotenvPathField ||
            field === customSizeField ||
            field === chatCommandField ||
            field === idleDelayField ||
            field === voiceShortcutField ||
            field === aiEndpointField {
            saveSettings()
            return
        }

        guard field.tag >= 0, field.tag < messages.count else {
            return
        }
        messages[field.tag] = field.stringValue
    }

    @objc private func addRAGFiles() {
        choosePaths(
            title: "RAGファイルを選択",
            canChooseDirectories: false,
            canChooseFiles: true,
            allowsMultipleSelection: true,
            allowedContentTypes: [.plainText, .text, .utf8PlainText, .json, .rtf],
            initialPath: ragFilePaths.first ?? "",
            onPick: { [weak self] urls in
                self?.appendRAGFileURLs(urls)
                self?.saveSettings()
            }
        )
    }

    @objc private func removeSelectedRAGFiles() {
        let selectedRows = ragFilesTableView.selectedRowIndexes
        guard !selectedRows.isEmpty else {
            return
        }
        ragFilePaths = ragFilePaths.enumerated().compactMap { selectedRows.contains($0.offset) ? nil : $0.element }
        ragFilesTableView.reloadData()
        updateRAGSummary()
        saveSettings()
    }

    private func appendRAGFileURLs(_ urls: [URL]) {
        var updated = ragFilePaths
        for url in urls {
            let path = url.path
            if !updated.contains(path) {
                updated.append(path)
            }
        }
        ragFilePaths = updated
        ragFilesTableView.reloadData()
        updateRAGSummary()
    }

    func syncRAGFiles(paths: [String]) {
        ragFilePaths = paths
        ragFilesTableView.reloadData()
        updateRAGSummary()
    }

    @objc private func sizePopupChanged() {
        if let size = sizePopup.selectedItem?.representedObject as? Double {
            customSizeField.stringValue = "\(Int(size))"
        }
    }

    @objc private func aiProviderChanged() {
        updateOllamaModelUI()
        let selectedProvider = aiProviderPopup.selectedItem?.representedObject as? String
        if selectedProvider == "Ollama" {
            refreshOllamaModelCandidates(selectedModel: settings.aiModel)
            if aiEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aiEndpointField.stringValue = PetSettings.ollamaDefaultEndpoint
            }
            ollamaSectionExpanded = true
            updateOllamaSectionVisibility()
        } else if selectedProvider == "Hermes Agent" {
            aiEndpointField.stringValue = PetSettings.hermesDefaultEndpoint
        } else if selectedProvider == "Genspark" {
            let trimmed = aiEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == PetSettings.defaults.aiEndpoint {
                aiEndpointField.stringValue = ""
            }
        }
        window?.makeFirstResponder(nil)
        saveSettings()
    }

    @objc private func toggleOllamaSection() {
        guard (aiProviderPopup.selectedItem?.representedObject as? String) == "Ollama" else {
            return
        }
        ollamaSectionExpanded.toggle()
        updateOllamaSectionVisibility()
    }

    @objc private func refreshOllamaModels() {
        refreshOllamaModelCandidates(selectedModel: settings.aiModel)
    }

    private func updateOllamaModelUI() {
        let isOllama = (aiProviderPopup.selectedItem?.representedObject as? String) == "Ollama"
        let isSakana = (aiProviderPopup.selectedItem?.representedObject as? String) == "SAKANA FUGU"
        if isOllama {
            aiEndpointField.stringValue = PetSettings.ollamaDefaultEndpoint
            aiEndpointField.isEditable = false
            aiEndpointField.isEnabled = false
            ollamaSectionExpanded = true
        } else if isSakana {
            aiEndpointField.stringValue = PetSettings.sakanaDefaultEndpoint
            aiEndpointField.isEditable = false
            aiEndpointField.isEnabled = false
        } else if (aiProviderPopup.selectedItem?.representedObject as? String) == "Hermes Agent" {
            aiEndpointField.stringValue = PetSettings.hermesDefaultEndpoint
            aiEndpointField.isEditable = true
            aiEndpointField.isEnabled = true
        } else {
            aiEndpointField.isEnabled = true
            aiEndpointField.isEditable = true
            ollamaSectionExpanded = false
        }
        sakanaModelStack.isHidden = !isSakana
        ollamaSectionStack.isHidden = !isOllama
        if isSakana {
            if sakanaModelButtons.isEmpty {
                rebuildSakanaModelButtons(selectedModel: settings.aiModel)
            }
        }
        if isOllama {
            refreshOllamaModelCandidates(selectedModel: settings.aiModel)
        }
        updateOllamaSectionVisibility()
    }

    private func updateOllamaSectionVisibility() {
        let isOllama = (aiProviderPopup.selectedItem?.representedObject as? String) == "Ollama"
        ollamaSectionStack.isHidden = !isOllama
        ollamaContentStack.isHidden = !ollamaSectionExpanded || !isOllama
        ollamaModelStack.isHidden = !isOllama || !ollamaSectionExpanded
        ollamaDisclosureButton.title = ollamaSectionExpanded ? "▼ Ollama設定" : "▶︎ Ollama設定"
        ollamaSectionStack.layer?.borderColor = (isOllama ? NSColor.systemBlue.withAlphaComponent(0.55) : NSColor.separatorColor.withAlphaComponent(0.6)).cgColor
        ollamaSectionStack.layer?.backgroundColor = (isOllama ? NSColor.systemBlue.withAlphaComponent(0.08) : NSColor.controlBackgroundColor).cgColor
        ollamaSectionStack.layer?.masksToBounds = true
    }

    private func refreshOllamaModelCandidates(selectedModel: String) {
        let candidates = loadOllamaModelCandidates()
        ollamaModelCandidates = candidates
        rebuildOllamaModelButtons(selectedModel: selectedModel, candidates: candidates)
    }

    private func rebuildSakanaModelButtons(selectedModel: String) {
        rebuildCheckboxOptions(
            into: sakanaModelButtonsStack,
            buttons: &sakanaModelButtons,
            options: SettingsConstants.sakanaModels,
            selectedValue: selectedModel.isEmpty ? SettingsConstants.defaultSakanaModel : selectedModel,
            action: #selector(sakanaModelCheckboxChanged(_:))
        )
    }

    private func rebuildOllamaModelButtons(selectedModel: String, candidates: [String]) {
        let options = candidates.isEmpty ? [selectedModel.isEmpty ? SettingsConstants.defaultOllamaModel : selectedModel] : candidates
        rebuildCheckboxOptions(
            into: ollamaModelButtonsStack,
            buttons: &ollamaModelButtons,
            options: options,
            selectedValue: selectedModel.isEmpty ? options.first ?? SettingsConstants.defaultOllamaModel : selectedModel,
            action: #selector(ollamaModelCheckboxChanged(_:))
        )
    }

    @objc private func sakanaModelCheckboxChanged(_ sender: NSButton) {
        ensureExclusiveSelection(in: sakanaModelButtons, selected: sender)
        window?.makeFirstResponder(nil)
        saveSettings()
    }

    @objc private func ollamaModelCheckboxChanged(_ sender: NSButton) {
        ensureExclusiveSelection(in: ollamaModelButtons, selected: sender)
        window?.makeFirstResponder(nil)
        saveSettings()
    }

    private func loadOllamaModelCandidates() -> [String] {
        guard let executable = ExecutableConstants.ollamaExecutableCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        process.arguments = ["list"]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else {
            return []
        }

        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var candidates: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("NAME") else { continue }
            let firstToken = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard !firstToken.isEmpty, firstToken.lowercased() != "error:" else { continue }
            if !candidates.contains(firstToken) {
                candidates.append(firstToken)
            }
        }
        return candidates
    }

    @objc private func saveSettings() {
        window?.makeFirstResponder(nil)
        var nextSettings = settings
        nextSettings.preferredPetID = (petPopup.selectedItem?.representedObject as? String) ?? settings.preferredPetID
        nextSettings.size = Double(customSizeField.stringValue) ?? (sizePopup.selectedItem?.representedObject as? Double) ?? settings.size
        nextSettings.chatCommand = chatCommandField.stringValue.split(separator: " ").map(String.init)
        nextSettings.notificationText = notificationTextField.stringValue
        nextSettings.notificationFile = notificationFileField.stringValue
        nextSettings.notificationDurationSeconds = min(max(Double(notificationDurationField.stringValue) ?? settings.notificationDurationSeconds, 1), 300)
        nextSettings.notificationWidth = min(max(Double(notificationWidthField.stringValue) ?? settings.notificationWidth, 20), 600)
        nextSettings.notificationHeight = min(max(Double(notificationHeightField.stringValue) ?? settings.notificationHeight, 80), 700)
        nextSettings.notificationFontSize = min(max(Double(notificationFontSizeField.stringValue) ?? settings.notificationFontSize, 10), 64)
        let logDirectory = chatLogDirectoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nextSettings.chatLogDirectoryPath = logDirectory.isEmpty ? PetSettings.defaults.chatLogDirectoryPath : logDirectory
        nextSettings.inputBubbleWidth = min(max(Double(inputBubbleWidthField.stringValue) ?? settings.inputBubbleWidth, 120), 1200)
        nextSettings.idleConversationEnabled = idleCheckbox.state == .on
        nextSettings.idleConversationDelaySeconds = Double(idleDelayField.stringValue) ?? settings.idleConversationDelaySeconds
        nextSettings.voiceInputEnabled = voiceInputCheckbox.state == .on
        nextSettings.voiceOutputEnabled = voiceOutputCheckbox.state == .on
        nextSettings.voiceIdentifier = (voicePopup.selectedItem?.representedObject as? String) ?? settings.voiceIdentifier
        nextSettings.voiceToggleShortcut = voiceShortcutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nextSettings.aiProvider = (aiProviderPopup.selectedItem?.representedObject as? String) ?? settings.aiProvider
        nextSettings.aiEndpoint = aiEndpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dotenvPath = dotenvPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        nextSettings.dotenvFilePath = dotenvPath.isEmpty ? PetSettings.defaults.dotenvFilePath : dotenvPath
        if nextSettings.aiProvider == "SAKANA FUGU" {
            if nextSettings.aiEndpoint.isEmpty || nextSettings.aiEndpoint == PetSettings.defaults.aiEndpoint {
                nextSettings.aiEndpoint = PetSettings.sakanaDefaultEndpoint
            }
            nextSettings.aiModel = selectedCheckboxValue(from: sakanaModelButtons, fallback: SettingsConstants.defaultSakanaModel)
        } else if nextSettings.aiProvider == "Ollama" {
            if nextSettings.aiEndpoint.isEmpty || nextSettings.aiEndpoint == PetSettings.defaults.aiEndpoint {
                nextSettings.aiEndpoint = PetSettings.ollamaDefaultEndpoint
            }
            nextSettings.aiModel = selectedCheckboxValue(from: ollamaModelButtons, fallback: SettingsConstants.defaultOllamaModel)
        } else if nextSettings.aiProvider == "Hermes Agent" {
            if nextSettings.aiEndpoint.isEmpty || nextSettings.aiEndpoint == PetSettings.defaults.aiEndpoint {
                nextSettings.aiEndpoint = PetSettings.hermesDefaultEndpoint
            }
            nextSettings.aiModel = SettingsConstants.defaultHermesModel
        } else if nextSettings.aiProvider == "Genspark" {
            nextSettings.aiModel = SettingsConstants.defaultGensparkModel
        } else {
            nextSettings.aiModel = nextSettings.aiProvider
        }
        nextSettings.aiSystemPrompt = aiSystemPromptField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        nextSettings.ragFilePaths = ragFilePaths
        if let generatedPetID {
            nextSettings.preferredPetID = generatedPetID
        }
        nextSettings.idleConversationMessages = messages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if nextSettings.idleConversationMessages.isEmpty {
            nextSettings.idleConversationMessages = PetSettings.defaults.idleConversationMessages
        }

        appLogger.info(
            "settings saved logDir=\(nextSettings.chatLogDirectoryPath, privacy: .public) notificationWidth=\(Int(nextSettings.notificationWidth), privacy: .public) notificationHeight=\(Int(nextSettings.notificationHeight), privacy: .public) fontSize=\(Int(nextSettings.notificationFontSize), privacy: .public) inputWidth=\(Int(nextSettings.inputBubbleWidth), privacy: .public) notificationTextLen=\(nextSettings.notificationText.count, privacy: .public) notificationFile=\(nextSettings.notificationFile, privacy: .public)"
        )

        settings = nextSettings
        messages = nextSettings.idleConversationMessages
        onSave(nextSettings)
    }

    @objc private func toggleSettingCheckbox() {
        saveSettings()
    }

    @objc private func generatePetFromImage() {
        let panel = NSOpenPanel()
        panel.title = "ペットにする画像を選択"
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            let name = url.deletingPathExtension().lastPathComponent
            let id = try assetGenerator.generate(from: url, displayName: name)
            generatedPetID = id
            onPetGenerated(id)
            let alert = NSAlert()
            alert.messageText = "ペット画像を作成しました"
            alert.informativeText = "静止・左右移動・上下運動・喜怒哀楽を含むスプライトを生成しました。保存ボタンでこのペットを適用します。"
            alert.runModal()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func chooseNotificationFile() {
        choosePath(
            title: "通知ファイルを選択",
            canChooseDirectories: false,
            canChooseFiles: true,
            allowedContentTypes: [.plainText, .text, .json, .rtf, .utf8PlainText, .commaSeparatedText, .tabSeparatedText],
            initialPath: notificationFileField.stringValue,
            onPick: { [weak self] url in
                self?.notificationFileField.stringValue = url.path
                appLogger.info("notification file picked \(url.path, privacy: .public)")
                self?.saveSettings()
            }
        )
    }

    @objc private func chooseLogDirectory() {
        choosePath(
            title: "ログ保存先フォルダを選択",
            canChooseDirectories: true,
            canChooseFiles: false,
            allowedContentTypes: [],
            initialPath: chatLogDirectoryField.stringValue,
            onPick: { [weak self] url in
                self?.chatLogDirectoryField.stringValue = url.path
                appLogger.info("chat log directory picked \(url.path, privacy: .public)")
                self?.saveSettings()
            }
        )
    }

    @objc private func chooseDotenvFile() {
        choosePath(
            title: ".envファイルを選択",
            canChooseDirectories: false,
            canChooseFiles: true,
            allowedContentTypes: [.plainText, .text, .utf8PlainText, .json],
            initialPath: dotenvPathField.stringValue,
            onPick: { [weak self] url in
                self?.dotenvPathField.stringValue = url.path
                appLogger.info(".env picked \(url.path, privacy: .public)")
                self?.saveSettings()
            }
        )
    }

    private func choosePath(
        title: String,
        canChooseDirectories: Bool,
        canChooseFiles: Bool,
        allowedContentTypes: [UTType],
        initialPath: String,
        onPick: @escaping (URL) -> Void
    ) {
        choosePaths(
            title: title,
            canChooseDirectories: canChooseDirectories,
            canChooseFiles: canChooseFiles,
            allowsMultipleSelection: false,
            allowedContentTypes: allowedContentTypes,
            initialPath: initialPath,
            onPick: { urls in
                if let first = urls.first {
                    onPick(first)
                }
            }
        )
    }

    private func choosePaths(
        title: String,
        canChooseDirectories: Bool,
        canChooseFiles: Bool,
        allowsMultipleSelection: Bool,
        allowedContentTypes: [UTType],
        initialPath: String,
        onPick: @escaping ([URL]) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = canChooseDirectories
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = allowsMultipleSelection
        if !allowedContentTypes.isEmpty {
            panel.allowedContentTypes = allowedContentTypes
        }
        let trimmed = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            panel.directoryURL = url.deletingLastPathComponent()
            if canChooseDirectories {
                panel.directoryURL = url
            }
        }
        guard panel.runModal() == .OK else {
            return
        }
        onPick(panel.urls)
    }

    @objc private func closeWindow() {
        window?.close()
    }
}

@MainActor
final class PetWindowController: SpriteViewDelegate {
    private let window: NSPanel
    private let bubbleWindow: NSPanel
    private let composerWindow: KeyablePetPanel
    private let spriteView: SpriteView
    private let bubbleView: BubbleView
    private let composerView: ComposerBubbleView
    private var notificationDuration: TimeInterval = NotificationConstants.defaultDuration
    private var notificationPanelWidth: CGFloat = NotificationConstants.defaultWidth
    private var notificationBaseHeight: CGFloat = NotificationConstants.defaultHeight
    private var notificationFontSize: CGFloat = NotificationConstants.defaultFontSize
    private var composerPanelWidth: CGFloat = NotificationConstants.defaultComposerWidth
    private let panelGap: CGFloat = UIConstants.panelGap
    private var logDirectoryPath: String = codexPetDefaultInboxPath()
    private var thinkingRequestCount = 0
    private var modelUsageStatus: AIModelUsageStatus?
    var notificationResizeHandler: ((CGFloat, CGFloat) -> Void)?

    init(size: CGFloat = 168) {
        spriteView = SpriteView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        window = NSPanel(
            contentRect: NSRect(x: 120, y: 120, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = spriteView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false

        bubbleView = BubbleView(frame: NSRect(x: 0, y: 0, width: notificationPanelWidth, height: 174))
        bubbleWindow = NSPanel(
            contentRect: NSRect(x: 120, y: 296, width: notificationPanelWidth, height: 174),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        bubbleWindow.contentView = bubbleView
        bubbleWindow.backgroundColor = .clear
        bubbleWindow.isOpaque = false
        bubbleWindow.hasShadow = true
        bubbleWindow.level = .floating
        bubbleWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubbleWindow.ignoresMouseEvents = false
        bubbleWindow.hidesOnDeactivate = false
        bubbleWindow.minSize = NSSize(width: 20, height: 80)
        bubbleView.closeHandler = { [weak bubbleWindow, weak bubbleView] in
            bubbleWindow?.orderOut(nil)
            bubbleView?.clearHistory()
        }

        composerView = ComposerBubbleView(frame: NSRect(x: 0, y: 0, width: composerPanelWidth, height: 178))
        composerWindow = KeyablePetPanel(
            contentRect: NSRect(x: 120, y: 296, width: composerPanelWidth, height: 178),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        composerWindow.contentView = composerView
        composerWindow.backgroundColor = .clear
        composerWindow.isOpaque = false
        composerWindow.hasShadow = true
        composerWindow.level = .floating
        composerWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        composerWindow.hidesOnDeactivate = false
        spriteView.delegate = self
        bubbleView.resizeHandler = { [weak self] size in
            self?.resizeBubble(to: size)
        }
    }

    var clickHandler: (() -> Void)?
    var doubleClickHandler: (() -> Void)?
    var settingsHandler: (() -> Void)?
    var contextMenuHandler: ((NSEvent, NSView) -> Void)?
    var moveStartHandler: (() -> Void)?
    var moveStopHandler: (() -> Void)?
    var ragFilesDroppedHandler: (([URL]) -> Void)?

    func show() {
        window.orderFrontRegardless()
        positionBubble()
        positionComposer()
    }

    func setPet(_ pet: Pet) {
        guard let sheet = SpriteSheet(url: pet.spritesheetURL) else {
            NSSound.beep()
            return
        }
        spriteView.setSpriteSheet(sheet)
        window.title = pet.manifest.displayName
    }

    func setSize(_ size: CGFloat) {
        var frame = window.frame
        frame.size = CGSize(width: size, height: size)
        window.setFrame(frame, display: true, animate: true)
        positionBubble()
        positionComposer()
    }

    func configureNotification(duration: TimeInterval, width: CGFloat, height: CGFloat, fontSize: CGFloat, composerWidth: CGFloat) {
        notificationDuration = min(max(duration, NotificationConstants.minDuration), NotificationConstants.maxDuration)
        notificationPanelWidth = min(max(width, UIConstants.minNotificationWidth), UIConstants.maxNotificationWidth)
        notificationBaseHeight = min(max(height, UIConstants.minNotificationHeight), UIConstants.maxNotificationHeight)
        notificationFontSize = min(max(fontSize, UIConstants.minNotificationFontSize), UIConstants.maxNotificationFontSize)
        composerPanelWidth = min(max(composerWidth, UIConstants.minComposerWidth), UIConstants.maxComposerWidth)
        bubbleView.setFontSize(notificationFontSize)
        var frame = bubbleWindow.frame
        frame.size = NSSize(
            width: notificationPanelWidth,
            height: notificationBaseHeight
        )
        bubbleWindow.setFrame(frame, display: true)
        var composerFrame = composerWindow.frame
        composerFrame.size.width = composerPanelWidth
        composerWindow.setFrame(composerFrame, display: true)
        bubbleView.needsLayout = true
        bubbleView.needsDisplay = true
        composerView.needsLayout = true
        composerView.needsDisplay = true
        bubbleWindow.contentView?.layoutSubtreeIfNeeded()
        composerWindow.contentView?.layoutSubtreeIfNeeded()
        positionBubble()
        positionComposer()
        let notificationFrame = bubbleWindow.frame
        let composerFrameAfter = composerWindow.frame
        appLogger.info(
            "panel frames notification=\(notificationFrame.width, privacy: .public)x\(notificationFrame.height, privacy: .public) composer=\(composerFrameAfter.width, privacy: .public)x\(composerFrameAfter.height, privacy: .public)"
        )
    }

    func resizeNotificationBubble(width: CGFloat, height: CGFloat) {
        configureNotification(
            duration: notificationDuration,
            width: width,
            height: height,
            fontSize: notificationFontSize,
            composerWidth: composerPanelWidth
        )
        notificationResizeHandler?(width, height)
    }

    func configureLogDirectoryPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        logDirectoryPath = trimmed
    }

    func showBubble(_ message: String, query: String? = nil, duration: TimeInterval? = nil, autoSize: Bool = false, persistLog: Bool = false) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            bubbleWindow.orderOut(nil)
            return
        }

        if persistLog {
            ChatLogStore.shared.appendMarkdownEntry(directoryPath: logDirectoryPath, speaker: "返答", text: trimmed)
        }
        let displayText = BubbleView.formattedNotificationText(trimmed)
        let targetWidth = bubbleView.preferredWidth(for: displayText, maximumWidth: notificationPanelWidth)
        let minimumBubbleHeight = bubbleView.preferredHeight(for: displayText, width: targetWidth, minimumLines: 3)
        let targetHeight = max(notificationBaseHeight, minimumBubbleHeight)
        if autoSize ||
            abs(targetWidth - bubbleWindow.frame.width) > 0.5 ||
            abs(targetHeight - bubbleWindow.frame.height) > 0.5 {
            var frame = bubbleWindow.frame
            frame.size.width = targetWidth
            frame.size.height = targetHeight
            bubbleWindow.setFrame(frame, display: true)
            bubbleWindow.contentView?.layoutSubtreeIfNeeded()
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayQuery = trimmedQuery.map { BubbleView.formattedNotificationText($0) }
        bubbleView.appendTurn(query: (displayQuery?.isEmpty == false) ? displayQuery : nil, response: displayText)
        composerWindow.orderOut(nil)
        positionBubble()
        bubbleWindow.orderFrontRegardless()
    }

    private func resizeBubble(to size: NSSize) {
        resizeNotificationBubble(width: size.width, height: size.height)
    }

    func playAnimation(row: Int) {
        spriteView.playAnimation(row: row)
    }

    func startThinking() {
        thinkingRequestCount += 1
        spriteView.setThinking(true)
    }

    func stopThinking() {
        thinkingRequestCount = max(0, thinkingRequestCount - 1)
        if thinkingRequestCount == 0 {
            spriteView.setThinking(false)
        }
    }

    fileprivate func setUsageStatus(_ status: CodexUsageStatus?) {
        spriteView.setUsageStatus(status)
    }

    func showComposer(
        modelName: String,
        onSend: @escaping (String) -> Void,
        onVoice: @escaping () -> Void
    ) {
        bubbleWindow.orderOut(nil)
        composerView.configure(modelName: modelName)
        composerView.setBusy(false)
        composerView.sendHandler = onSend
        composerView.voiceHandler = onVoice
        positionComposer()
        composerWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        composerView.focusInput()
    }

    func setComposerInput(_ text: String) {
        composerView.setInput(text)
    }

    func setComposerBusy(_ busy: Bool) {
        composerView.setBusy(busy)
    }

    func updateModelUsageDisplay(_ status: AIModelUsageStatus) {
        modelUsageStatus = status
        spriteView.setModelUsageStatus(status)
    }

    func hideComposer() {
        composerWindow.orderOut(nil)
    }

    func dismissComposerIfClickOutside(at screenPoint: NSPoint) {
        guard composerWindow.isVisible else {
            return
        }
        let clickedPet = window.frame.contains(screenPoint)
        let clickedComposer = composerWindow.frame.contains(screenPoint)
        if !clickedPet, !clickedComposer {
            hideComposer()
        }
    }

    private func positionBubble() {
        bubbleWindow.setFrameOrigin(positionAbovePet(for: bubbleWindow.frame.size))
    }

    private func positionComposer() {
        composerWindow.setFrameOrigin(positionBelowPet(for: composerWindow.frame.size))
    }

    private func positionAbovePet(for panelSize: NSSize) -> NSPoint {
        position(for: panelSize, preferredY: { petFrame, _ in petFrame.maxY + panelGap })
    }

    private func positionBelowPet(for panelSize: NSSize) -> NSPoint {
        position(for: panelSize, preferredY: { petFrame, _ in petFrame.minY - panelSize.height - panelGap })
    }

    private func position(for panelSize: NSSize, preferredY: (NSRect, NSRect) -> CGFloat) -> NSPoint {
        let petFrame = window.frame
        let screen = window.screen ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: DialogConstants.defaultScreenWidth, height: DialogConstants.defaultScreenHeight)
        let margin = UIConstants.screenMargin
        let desiredX = petFrame.midX - panelSize.width / 2
        let clampedX = min(
            max(desiredX, visibleFrame.minX + margin),
            visibleFrame.maxX - panelSize.width - margin
        )
        let desiredY = preferredY(petFrame, visibleFrame)
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - panelSize.height - margin
        let clampedY = max(minY, min(desiredY, maxY))
        return NSPoint(x: clampedX, y: clampedY)
    }

    func spriteViewDidClick(_ spriteView: SpriteView) {
        clickHandler?()
    }

    func spriteViewDidDoubleClick(_ spriteView: SpriteView) {
        doubleClickHandler?()
    }

    func spriteViewDidRequestSettings(_ spriteView: SpriteView) {
        settingsHandler?()
    }

    func spriteViewDidRequestContextMenu(_ spriteView: SpriteView, event: NSEvent) {
        contextMenuHandler?(event, spriteView)
    }

    func spriteViewDidStartMoving(_ spriteView: SpriteView) {
        moveStartHandler?()
    }

    func spriteViewDidStopMoving(_ spriteView: SpriteView) {
        moveStopHandler?()
    }

    func spriteView(_ spriteView: SpriteView, didDropFileURLs urls: [URL]) {
        ragFilesDroppedHandler?(urls)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let petStore = PetStore()
    private let settingsStore = SettingsStore()
    private let petWindow = PetWindowController()
    private let voiceController = VoiceController()
    private let secretStore = SecretStore()
    private lazy var aiClient = AIChatClient(secretStore: secretStore)
    private let organizerStore = OrganizerStore()
    private let notificationService = PetNotificationService()
    private var statusItem: NSStatusItem?
    private var pets: [Pet] = []
    private var settings = PetSettings.defaults
    private var settingsTimer: Timer?
    private var usageTimer: Timer?
    private var idleTimer: Timer?
    private var shortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    private var outsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var lastNotification = ""
    private var idleMessageIndex = 0
    private var recentGeneratedMessages: [String] = []
    private var currentPetID = ""
    private var currentSize: Double = 0
    private var settingsWindowController: SettingsWindowController?
    private var chatWindowController: ChatWindowController?
    private var organizerWindowController: OrganizerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = settingsStore.load()
        pets = petStore.loadPets()
        secretStore.configure(dotenvFilePath: settings.dotenvFilePath)
        petWindow.clickHandler = { [weak self] in
            self?.continueConversationFromClick()
        }
        petWindow.doubleClickHandler = { [weak self] in
            self?.startIdleConversation(force: true)
        }
        petWindow.notificationResizeHandler = { [weak self] width, height in
            guard let self else { return }
            self.settings.notificationWidth = Double(width)
            self.settings.notificationHeight = Double(height)
            self.settingsStore.save(self.settings)
            appLogger.info("notification resized width=\(width, privacy: .public) height=\(height, privacy: .public)")
        }
        petWindow.settingsHandler = { [weak self] in
            self?.showSettingsWindow()
        }
        petWindow.contextMenuHandler = { [weak self] event, view in
            self?.showPetContextMenu(event: event, for: view)
        }
        petWindow.moveStartHandler = { [weak self] in
            self?.petWindow.hideComposer()
            self?.markActivity()
        }
        petWindow.moveStopHandler = { [weak self] in
            self?.markActivity()
        }
        petWindow.ragFilesDroppedHandler = { [weak self] urls in
            self?.appendRAGFiles(from: urls)
        }
        configureMenu()
        notificationService.requestAuthorization()

        if let preferredPet = pets.first(where: { $0.manifest.id == settings.preferredPetID }) ?? pets.first {
            petWindow.setPet(preferredPet)
        }
        petWindow.setSize(settings.size)
        applyNotificationAppearance()
        petWindow.show()
        configureVoice()
        installShortcutMonitors()
        installOutsideClickMonitors()
        startSettingsPolling()
        startUsageMonitoring()
        scheduleIdleConversation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageTimer?.invalidate()
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
        }
    }

    private func startUsageMonitoring() {
        usageTimer?.invalidate()
        refreshUsageRemaining()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsageRemaining()
            }
        }
    }

    private func refreshUsageRemaining() {
        Task {
            let status = await Task.detached(priority: .utility) {
                CodexUsageReader.status()
            }.value
            petWindow.setUsageStatus(status)
        }
    }

    private func installOutsideClickMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.petWindow.dismissComposerIfClickOutside(at: NSEvent.mouseLocation)
            }
        }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.petWindow.dismissComposerIfClickOutside(at: NSEvent.mouseLocation)
            return event
        }
    }

    private func configureMenu() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Pet"
        statusItem.menu = buildPetMenu()
        self.statusItem = statusItem
    }

    private func buildPetMenu() -> NSMenu {
        let menu = NSMenu()

        let startChat = NSMenuItem(title: "Start Chat", action: #selector(startChatFromMenu), keyEquivalent: "")
        startChat.target = self
        menu.addItem(startChat)
        let organizer = NSMenuItem(title: "Todo・スケジュール", action: #selector(openOrganizer), keyEquivalent: "")
        organizer.target = self
        menu.addItem(organizer)
        let openSettings = NSMenuItem(title: "Open Settings Window...", action: #selector(openSettingsWindow), keyEquivalent: "")
        openSettings.target = self
        menu.addItem(openSettings)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }


    private func showPetContextMenu(event: NSEvent, for view: NSView) {
        NSMenu.popUpContextMenu(buildPetMenu(), with: event, for: view)
    }

    @objc private func startChatFromMenu() {
        startChat()
    }

    @objc private func openSettingsWindow() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        if let controller = settingsWindowController {
            controller.syncDisplayedSettings(settings)
            controller.show()
        } else {
            let controller = SettingsWindowController(
                pets: pets,
                settings: settings,
                onPetGenerated: { [weak self] id in
                    self?.reloadPets(selecting: id)
                },
                onSave: { [weak self] newSettings in
                    self?.saveSettingsFromWindow(newSettings)
                }
            )
            settingsWindowController = controller
            controller.show()
        }
        markActivity()
    }

    private func saveSettingsFromWindow(_ newSettings: PetSettings) {
        let oldSettings = settings
        settings = newSettings
        settingsStore.save(newSettings)
        applySettings(previousSettings: oldSettings)
        settingsWindowController?.syncDisplayedSettings(newSettings)
        configureVoice()
        installShortcutMonitors()
        refreshMenu()
        markActivity()
    }

    private func appendRAGFiles(from urls: [URL]) {
        let filePaths = urls
            .filter { $0.isFileURL }
            .map(\.path)
        guard !filePaths.isEmpty else {
            return
        }

        var updated = settings.ragFilePaths
        for path in filePaths {
            if !updated.contains(path) {
                updated.append(path)
            }
        }
        guard updated != settings.ragFilePaths else {
            return
        }
        settings.ragFilePaths = updated
        settingsStore.save(settings)
        settingsWindowController?.syncRAGFiles(paths: updated)
        petWindow.showBubble("RAGファイルを追加しました。")
        appLogger.info("rag files added count=\(filePaths.count, privacy: .public) total=\(updated.count, privacy: .public)")
        markActivity()
    }

    private func startSettingsPolling() {
        settingsTimer?.invalidate()
        settingsTimer = Timer.scheduledTimer(withTimeInterval: SettingsConstants.settingsCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadSettings()
                self?.updateModelUsageDisplay()
            }
        }
        reloadSettings()
        updateModelUsageDisplay()
    }

    private func updateModelUsageDisplay() {
        let modelUsage = currentProviderUsageStatus()
        petWindow.updateModelUsageDisplay(modelUsage)
    }

    private func currentProviderUsageStatus() -> AIModelUsageStatus {
        switch settings.aiProvider {
        case "codex":
            if let codexStatus = CodexUsageReader.status() {
                return AIModelUsageStatus(
                    provider: "Codex",
                    remainingPercent: codexStatus.remainingPercent,
                    isExhausted: codexStatus.isExhausted
                )
            }
        case "claudeCode":
            return AIModelUsageStatus(provider: "Claude Code", remainingPercent: 100, isExhausted: false)
        case "Gemini":
            return AIModelUsageStatus(provider: "Gemini", remainingPercent: 100, isExhausted: false)
        case "SAKANA FUGU":
            return AIModelUsageStatus(provider: "Sakana", remainingPercent: 100, isExhausted: false)
        case "Ollama":
            return AIModelUsageStatus(provider: "Ollama", remainingPercent: 100, isExhausted: false)
        case "Hermes Agent":
            return AIModelUsageStatus(provider: "Hermes", remainingPercent: 100, isExhausted: false)
        case "Genspark":
            return AIModelUsageStatus(provider: "Genspark", remainingPercent: 100, isExhausted: false)
        default:
            return AIModelUsageStatus(provider: "Unknown", remainingPercent: 100, isExhausted: false)
        }
        return AIModelUsageStatus(provider: "Codex", remainingPercent: 0, isExhausted: true)
    }

    private func reloadSettings() {
        let oldSettings = settings
        settings = settingsStore.load()
        applySettings(previousSettings: oldSettings)
        if oldSettings != settings {
            configureVoice()
            installShortcutMonitors()
            refreshMenu()
            settingsWindowController?.syncDisplayedSettings(settings)
        }
        let notification = currentNotificationText(from: settings)
        if !notification.isEmpty, notification != lastNotification {
            petWindow.showBubble(notification)
        }
        lastNotification = notification
    }

    private func applySettings(previousSettings: PetSettings) {
        secretStore.configure(dotenvFilePath: settings.dotenvFilePath)
        let currentSettings = settings
        appLogger.info(
            "applySettings logDir=\(currentSettings.chatLogDirectoryPath, privacy: .public) notificationWidth=\(Int(currentSettings.notificationWidth), privacy: .public) notificationHeight=\(Int(currentSettings.notificationHeight), privacy: .public) fontSize=\(Int(currentSettings.notificationFontSize), privacy: .public) inputWidth=\(Int(currentSettings.inputBubbleWidth), privacy: .public) notificationTextLen=\(currentSettings.notificationText.count, privacy: .public) notificationFile=\(currentSettings.notificationFile, privacy: .public)"
        )
        if settings.preferredPetID != currentPetID, let pet = pets.first(where: { $0.manifest.id == settings.preferredPetID }) {
            petWindow.setPet(pet)
            currentPetID = settings.preferredPetID
        }
        if abs(settings.size - currentSize) > 0.5 {
            petWindow.setSize(settings.size)
            currentSize = settings.size
        }
        petWindow.configureLogDirectoryPath(settings.chatLogDirectoryPath)
        chatWindowController?.configureLogDirectoryPath(settings.chatLogDirectoryPath)
        if previousSettings.voiceOutputEnabled && !settings.voiceOutputEnabled {
            voiceController.stopSpeaking()
        }
        applyNotificationAppearance()
        if idleSettingsChanged(from: previousSettings, to: settings) {
            scheduleIdleConversation()
        }
    }

    private func applyNotificationAppearance() {
        let currentSettings = settings
        appLogger.info(
            "applyNotificationAppearance duration=\(currentSettings.notificationDurationSeconds, privacy: .public) width=\(currentSettings.notificationWidth, privacy: .public) height=\(currentSettings.notificationHeight, privacy: .public) fontSize=\(currentSettings.notificationFontSize, privacy: .public) composerWidth=\(currentSettings.inputBubbleWidth, privacy: .public)"
        )
        petWindow.configureNotification(
            duration: currentSettings.notificationDurationSeconds,
            width: currentSettings.notificationWidth,
            height: currentSettings.notificationHeight,
            fontSize: currentSettings.notificationFontSize,
            composerWidth: currentSettings.inputBubbleWidth
        )
    }

    private func idleSettingsChanged(from oldSettings: PetSettings, to newSettings: PetSettings) -> Bool {
        oldSettings.idleConversationEnabled != newSettings.idleConversationEnabled ||
            abs(oldSettings.idleConversationDelaySeconds - newSettings.idleConversationDelaySeconds) > 0.5 ||
            oldSettings.idleConversationMessages != newSettings.idleConversationMessages
    }

    private func currentNotificationText(from settings: PetSettings) -> String {
        let directText = settings.notificationText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directText.isEmpty {
            appLogger.info("notification source=direct length=\(directText.count, privacy: .public)")
            return directText
        }

        let filePath = settings.notificationFile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filePath.isEmpty else {
            return ""
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath) else {
            appLogger.info("notification source=file missing path=\(expandedPath, privacy: .public)")
            return ""
        }
        let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appLogger.info("notification source=file path=\(expandedPath, privacy: .public) length=\(content.count, privacy: .public)")
        return content
    }

    private func startChat() {
        markActivity()
        if chatWindowController == nil {
            let controller = ChatWindowController(client: aiClient, settingsProvider: { [weak self] in
                self?.settings ?? .defaults
            }, logDirectoryPath: settings.chatLogDirectoryPath)
            controller.responseHandler = { [weak self] query, response in
                self?.petWindow.showBubble(response, query: query)
                guard let self else { return }
                self.voiceController.speak(response, enabled: self.settings.voiceOutputEnabled)
            }
            controller.thinkingStateHandler = { [weak self] thinking in
                if thinking {
                    self?.petWindow.startThinking()
                } else {
                    self?.petWindow.stopThinking()
                }
            }
            chatWindowController = controller
        }
        chatWindowController?.show()
    }

    private func startExternalChat() {
        let command = settings.chatCommand.isEmpty ? PetSettings.defaults.chatCommand : settings.chatCommand
        guard let executable = command.first else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())

        do {
            try process.run()
        } catch {
            NSSound.beep()
            petWindow.showBubble("Failed to start chat: \(error.localizedDescription)")
        }
    }

    @objc private func openOrganizer() {
        if organizerWindowController == nil {
            organizerWindowController = OrganizerWindowController(store: organizerStore, notifications: notificationService)
        }
        organizerWindowController?.show()
        markActivity()
    }

    @objc private func playEmotion(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int else { return }
        petWindow.playAnimation(row: row)
        markActivity()
    }

    private func reloadPets(selecting id: String? = nil) {
        pets = petStore.loadPets()
        if let id, let pet = pets.first(where: { $0.manifest.id == id }) {
            settings.preferredPetID = id
            settingsStore.save(settings)
            petWindow.setPet(pet)
            currentPetID = id
        }
        refreshMenu()
    }

    private func refreshMenu() {
        statusItem?.menu = buildPetMenu()
    }

    private func configureVoice() {
        voiceController.configure(voiceIdentifier: settings.voiceIdentifier)
    }

    private func installShortcutMonitors() {
        if let shortcutMonitor {
            NSEvent.removeMonitor(shortcutMonitor)
            self.shortcutMonitor = nil
        }
        if let localShortcutMonitor {
            NSEvent.removeMonitor(localShortcutMonitor)
            self.localShortcutMonitor = nil
        }

        guard let shortcut = KeyboardShortcut(settings.voiceToggleShortcut) else {
            return
        }

        shortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard shortcut.matches(event) else {
                return
            }
            Task { @MainActor in
                self?.toggleVoice()
            }
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard shortcut.matches(event) else {
                return event
            }
            self?.toggleVoice()
            return nil
        }
    }

    @objc private func toggleVoice() {
        let nextEnabled = !settings.voiceOutputEnabled
        settings.voiceOutputEnabled = nextEnabled
        settingsStore.save(settings)
        configureVoice()
        refreshMenu()
        let message = nextEnabled ? "音声出力をオンにしました。" : "音声出力をオフにしました。"
        petWindow.showBubble(message)
        voiceController.speak(message, enabled: settings.voiceOutputEnabled)
        markActivity()
    }

    private func continueConversationFromClick() {
        markActivity()
        appLogger.info("composer requested from pet click")
        petWindow.showComposer(
            modelName: settings.aiProvider,
            onSend: { [weak self] text in
                self?.sendMessageFromPetComposer(text)
            },
            onVoice: { [weak self] in
                self?.startComposerVoiceInput()
            }
        )
    }

    private func sendMessageFromPetComposer(_ text: String) {
        appLogger.info("composer send requested length=\(text.count, privacy: .public)")
        ChatLogStore.shared.appendMarkdownEntry(directoryPath: settings.chatLogDirectoryPath, speaker: "あなた", text: text)
        petWindow.setComposerBusy(true)
        petWindow.startThinking()
        Task {
            defer {
                petWindow.stopThinking()
            }
            do {
                let response = try await aiClient.reply(
                    to: [ChatMessage(role: "user", content: text)],
                    settings: settings
                )
                petWindow.hideComposer()
                appLogger.info("composer response shown length=\(response.count, privacy: .public)")
                ChatLogStore.shared.appendMarkdownEntry(directoryPath: settings.chatLogDirectoryPath, speaker: "返答", text: response)
                petWindow.showBubble(response, query: text, persistLog: false)
                voiceController.speak(response, enabled: settings.voiceOutputEnabled)
            } catch {
                petWindow.setComposerBusy(false)
                appLogger.info("composer error=\(error.localizedDescription, privacy: .public)")
                petWindow.showBubble(error.localizedDescription)
            }
            markActivity()
        }
    }

    private func startComposerVoiceInput() {
        guard settings.voiceInputEnabled else {
            petWindow.showBubble("音声入力はオフです。設定画面で有効にしてください。")
            return
        }
        petWindow.setComposerInput("聞き取り中です…")
        voiceController.startListening { [weak self] text in
            self?.petWindow.setComposerInput(text)
            self?.markActivity()
        } onError: { [weak self] message in
            self?.petWindow.setComposerInput("")
            self?.petWindow.showBubble(message)
        }
    }

    private func generateNewConversationMessage() async -> String {
        let personality = settings.aiSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let personalityDescription = personality.isEmpty
            ? "親しみやすく、穏やかで、簡潔に話す小さな相棒"
            : personality
        let recentMessages = recentGeneratedMessages.isEmpty
            ? "なし"
            : recentGeneratedMessages.map { "・\($0)" }.joined(separator: "\n")
        let request = """
        次の「ペットの性格」を最優先して、デスクトップペットの日常会話を1つ作ってください。

        ペットの性格:
        \(personalityDescription)

        性格から、話題の選び方、ユーザーとの距離感、言葉遣い、語尾、テンポ、感情の強さ、ユーモアの有無を自然に決めてください。
        性格の説明をそのまま読み上げたり、「この性格なので」などの解説をしたりしないでください。
        60文字から110文字程度の日本語で、質問、気づき、小さな提案、雑学などを自然に混ぜてください。
        毎回新しい内容にし、次の最近の会話と同じ話題や言い回しを避けてください。

        最近の会話:
        \(recentMessages)

        かぎ括弧、番号、説明文は付けないでください。
        """

        let generated: String
        do {
            generated = try await aiClient.reply(
                to: [ChatMessage(role: "user", content: request)],
                settings: settings
            )
        } catch {
            generated = localGeneratedConversation(personality: personalityDescription)
        }

        let cleaned = generated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
        let result = cleaned.isEmpty
            ? localGeneratedConversation(personality: personalityDescription)
            : cleaned
        recentGeneratedMessages.append(result)
        recentGeneratedMessages = Array(recentGeneratedMessages.suffix(ConversationConstants.recentMessageHistorySize))
        return result
    }

    private func localGeneratedConversation(personality: String) -> String {
        for _ in 0..<ConversationConstants.minGenerationAttempts {
            let candidate = "\(ConversationConstants.openings.randomElement()!)\(ConversationConstants.topics.randomElement()!)\(ConversationConstants.closings.randomElement()!)"
            if !recentGeneratedMessages.contains(candidate) {
                return personalityAdjustedFallback(candidate, personality: personality)
            }
        }
        return personalityAdjustedFallback(
            ConversationConstants.defaultFallbackMessage,
            personality: personality
        )
    }

    private func personalityAdjustedFallback(_ message: String, personality: String) -> String {
        let normalized = personality.lowercased()
        if normalized.contains("元気") || normalized.contains("明る") || normalized.contains("活発") {
            return "よーし、今日も小さく前進です！\(message)"
        }
        if normalized.contains("クール") || normalized.contains("無口") || normalized.contains("冷静") {
            return "ひと息つこう。\(message)"
        }
        if normalized.contains("丁寧") || normalized.contains("執事") || normalized.contains("上品") {
            return "よろしければ、少し休憩になさいませんか。\(message)"
        }
        if normalized.contains("甘え") || normalized.contains("寂し") || normalized.contains("かわい") {
            return "少しだけ、私と一緒に休憩しませんか？\(message)"
        }
        return message
    }

    private func startVoiceListening() {
        guard settings.voiceInputEnabled else {
            petWindow.showBubble("音声入力はオフです。設定画面で有効にしてください。")
            return
        }
        petWindow.showBubble("聞き取り中です。話してください。")
        voiceController.startListening { [weak self] text in
            guard let self else {
                return
            }
            Task {
                self.petWindow.startThinking()
                defer {
                    self.petWindow.stopThinking()
                }
                ChatLogStore.shared.appendMarkdownEntry(directoryPath: self.settings.chatLogDirectoryPath, speaker: "あなた", text: text)
                let fallback = self.responseForRecognizedSpeech(text)
                let response: String
                do {
                    response = try await self.aiClient.reply(
                        to: [ChatMessage(role: "user", content: text)],
                        settings: self.settings
                    )
                } catch {
                    response = fallback
                }
                ChatLogStore.shared.appendMarkdownEntry(directoryPath: self.settings.chatLogDirectoryPath, speaker: "返答", text: response)
                self.petWindow.showBubble(response, query: text, persistLog: false)
                self.voiceController.speak(response, enabled: self.settings.voiceOutputEnabled)
                self.markActivity()
            }
        } onError: { [weak self] message in
            self?.petWindow.showBubble(message)
        }
    }

    private func responseForRecognizedSpeech(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "うまく聞き取れませんでした。もう一度ゆっくり話してみてください。"
        }
        return "「\(trimmed)」ですね。続きを一緒に考えましょう。"
    }

    private func markActivity() {
        scheduleIdleConversation()
    }

    private func scheduleIdleConversation() {
        idleTimer?.invalidate()
        guard settings.idleConversationEnabled else {
            return
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: settings.idleConversationDelaySeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.startIdleConversation()
            }
        }
    }

    private func startIdleConversation(force: Bool = false) {
        guard force || settings.idleConversationEnabled else {
            return
        }

        petWindow.startThinking()
        Task {
            defer {
                petWindow.stopThinking()
            }
            let message = await generateNewConversationMessage()
            guard force || settings.idleConversationEnabled else {
                return
            }
            petWindow.showBubble(message, autoSize: true, persistLog: false)
            voiceController.speak(message, enabled: settings.voiceOutputEnabled)
            if settings.idleConversationEnabled {
                scheduleIdleConversation()
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
