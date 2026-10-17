import AppKit
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Explicitly approved, Telegram-only context fallback. This is a picture of
/// the gesture area (which can contain nearby messages), never selected text,
/// OCR, a clipboard read, a delivery target, or a full-screen screenshot.
enum TelegramSelectionImageCapture {
    static let preferenceKey = "VIPPTelegramHighlightImageFallbackEnabled"
    static let bundleID = "ru.keepcoder.Telegram"
    @MainActor private static var captureInFlight = false

    static func mayCapture(enabled: Bool, sourceBundleID: String?, precedesSpeech: Bool,
                           gesture: LiveSelectionGesture?, resolution: LiveSelectionResolution?) -> Bool {
        guard enabled, sourceBundleID == bundleID, !precedesSpeech,
              let gesture, let resolution, resolution.accessibilityTrusted,
              resolution.candidate == nil, resolution.examinedElements == 0,
              resolution.emptyHitTests == gesture.hitTestPoints.count,
              resolution.refusedSecure == 0, resolution.rejectedElsewhere == 0,
              resolution.rejectedOutsideSourceWindow == 0, !resolution.budgetExhausted else { return false }
        return true
    }

    /// Window-local, top-left coordinates. Bound the capture to the endpoints
    /// plus reading context, not the whole chat. Multi-click has no glyph bounds,
    /// so its small surrounding region is explicitly not an exact selection.
    static func cropRect(gesture: LiveSelectionGesture, window: CGRect) -> CGRect? {
        guard window.width.isFinite, window.height.isFinite, window.width > 0, window.height > 0,
              window.width <= 16_384, window.height <= 16_384,
              window.contains(gesture.mouseDown), window.contains(gesture.mouseUp) else { return nil }
        let dx = abs(gesture.mouseUp.x - gesture.mouseDown.x)
        let dy = abs(gesture.mouseUp.y - gesture.mouseDown.y)
        let stationary = dx * dx + dy * dy < 16
        guard !stationary || gesture.clickCount >= 2 else { return nil }
        let paddingX: CGFloat = stationary ? 240 : 48
        let paddingY: CGFloat = stationary ? 48 : 36
        let global = CGRect(x: min(gesture.mouseDown.x, gesture.mouseUp.x) - paddingX,
                            y: min(gesture.mouseDown.y, gesture.mouseUp.y) - paddingY,
                            width: dx + 2 * paddingX, height: dy + 2 * paddingY).intersection(window)
        guard !global.isEmpty else { return nil }
        return global.offsetBy(dx: -window.minX, dy: -window.minY)
    }

    @MainActor
    static func capture(identity: LiveSelectionReadIdentity, gesture: LiveSelectionGesture) async -> URL? {
        guard !captureInFlight, !Task.isCancelled, CGPreflightScreenCaptureAccess(),
              let source = identity.window, let windowID = source.windowID,
              let crop = cropRect(gesture: gesture, window: source.bounds), isCurrent(identity) else { return nil }
        captureInFlight = true
        defer { captureInFlight = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled, isCurrent(identity),
                  let window = content.windows.first(where: {
                      $0.windowID == windowID && $0.owningApplication?.processID == identity.processIdentifier
                          && $0.windowLayer == 0 && $0.frame == source.bounds
                  }) else { return nil }
            let config = SCStreamConfiguration()
            // Capture only this window, without shadows/cursor/other windows.
            // A bounded 1x window image avoids Retina-sized full-screen buffers;
            // encode only the crop off the main thread, then release the frame.
            let scale = min(1, 2_048 / max(window.frame.width, window.frame.height))
            config.width = max(1, Int(window.frame.width * scale))
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let frame = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard !Task.isCancelled, isCurrent(identity) else { return nil }
            let pixels = CGRect(x: crop.minX * CGFloat(frame.width) / window.frame.width,
                                y: crop.minY * CGFloat(frame.height) / window.frame.height,
                                width: crop.width * CGFloat(frame.width) / window.frame.width,
                                height: crop.height * CGFloat(frame.height) / window.frame.height).integral
            guard let image = frame.cropping(to: pixels), image.width >= 8, image.height >= 8 else { return nil }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentFlow/SelectionImages", isDirectory: true)
            let url = try await Task.detached(priority: .userInitiated) {
                try save(image, directory: directory)
            }.value
            guard !Task.isCancelled, isCurrent(identity) else { discard(url); return nil }
            return url
        } catch { return nil }
    }

    @MainActor
    private static func isCurrent(_ identity: LiveSelectionReadIdentity) -> Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processIdentifier
            && identity.isValid(frontmostPID: identity.processIdentifier, windows: LiveSelectionWindow.onScreen())
    }

    static func save(_ image: CGImage, directory: URL) throws -> URL {
        let data = NSMutableData()
        guard image.width * image.height <= 4_194_304, hasVisibleContent(image),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 16 * 1_024 * 1_024
        else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let dirFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dirFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(dirFD) }
        var info = stat()
        guard fstat(dirFD, &info) == 0, info.st_uid == getuid(), fchmod(dirFD, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let name = "telegram-highlight-\(UUID().uuidString.lowercased()).png"
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var complete = false
        defer { Darwin.close(fd); if !complete { unlinkat(dirFD, name, 0) } }
        let bytes = data as Data
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(fd) == 0, fsync(dirFD) == 0 else { throw CocoaError(.fileWriteUnknown) }
        complete = true
        return directory.appendingPathComponent(name)
    }

    static func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// Reject blank/protected buffers; this checks only pixel variation, never
    /// characters, highlights, chat identity or OCR-derived content.
    static func hasVisibleContent(_ image: CGImage) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 4)
        return bytes.withUnsafeMutableBytes { pixels in
            guard let context = CGContext(data: pixels.baseAddress, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let rgba = pixels.bindMemory(to: UInt8.self)
            let red = Int(rgba[0]), green = Int(rgba[1]), blue = Int(rgba[2])
            for i in stride(from: 0, to: rgba.count, by: 4) where rgba[i + 3] > 16 {
                if abs(Int(rgba[i]) - red) > 8 { return true }
                if abs(Int(rgba[i + 1]) - green) > 8 { return true }
                if abs(Int(rgba[i + 2]) - blue) > 8 { return true }
            }
            return false
        }
    }
}
