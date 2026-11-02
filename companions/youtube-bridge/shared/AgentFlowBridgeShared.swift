import Foundation
import Darwin

enum MediaOwner: String {
  case spotify
  case youtube
}

enum SpotifyState: String {
  case notRunning
  case paused
  case playing
  case stopped
  case unknown
}

struct BridgeMessage: Codable {
  var type: String
  var bridgeId: String?
  var tabId: Int?
  var title: String?
  var url: String?
  var playing: Bool?
  var reason: String?
  var currentTime: Double?
  var duration: Double?
  var paused: Bool?
  var resumed: Bool?
  // A directional browser seek is deliberately explicit rather than a playback toggle. `seekSeconds`
  // is negative for backwards movement; Agentic Mouse emits exactly -5 or +5.
  var jumpAheadClicked: Bool?
  var sought: Bool?
  var seekSeconds: Double?
  // Agentic Mouse emits only fixed five-percentage-point YouTube volume steps.
  var volumeAdjusted: Bool?
  var volumeDelta: Double?
  var volume: Double?
  var muted: Bool?
  // Agentic Mouse's bounded YouTube speed hold. The opaque token ties begin,
  // renew, and end to one physical press; the content script restores the
  // exact previous rate when the lease expires even if release is lost.
  var holdToken: String?
  var playbackRate: Double?
  var holdLeaseMilliseconds: Int?
  var speedHeld: Bool?
  var previousPlaybackRate: Double?
  // Present only when an explicit sticky-speed unlock must land at 1×.
  // Ordinary hold release omits it and restores the video's exact prior rate.
  var restorePlaybackRate: Double?
  // Chrome mode's held-wheel control traverses per-window activation history rather than the
  // browser's spatial tab strip. Only exact back/forward values cross the native boundary.
  var tabHistoryDirection: String?
  var tabHistoryMoved: Bool?
  // Chrome website shortcuts cross the bridge as a fixed identifier. Only the extension maps that
  // identifier to its allow-listed URL, so no caller can turn this into arbitrary navigation.
  var chromeWebsite: String?
  var chromeWebsiteOpened: Bool?
  // The most-recently-played timestamp (ms) of the tab the EXTENSION chose to pause for a dictation.
  // Echoed back in youtube-pause-result purely so a future "it paused the wrong tab" miss is
  // diagnosable from the single log file — the extension now owns the tab-selection decision.
  var lastPlayedAt: Int?
  var extensionTimestamp: Int?
  var contentTimestamp: Int?
  var lastMediaOwner: String?
  var spotifyState: String?
  var youtubeTabId: Int?
  var accessibilityTrusted: Bool?
  var mediaKeyTapInstalled: Bool?
  var mediaKeyTapError: String?
  var appRunning: Bool?
  var bridgeConnected: Bool?
  var message: String?
  var voiceInkRecordingActive: Bool?
  var voiceInkPausePending: Bool?
  var voiceInkResumePendingTabId: Int?
  var voiceInkResumeAttemptCount: Int?
  var youtubePausedForDictationTabId: Int?
  var nativeTimestamp: Int?

  init(type: String) {
    self.type = type
  }
}

// VoiceInk++ dictation IPC contract.
//
// VoiceInk++ (bundle com.ethansk.VoiceInkPlusPlus) POSTs these DistributedNotificationCenter
// notifications from its recorder lifecycle — `recordingStarted` when a dictation recording begins
// and `recordingStopped` when it ends (including cancel; at the recorder layer cancel == stop).
// The menu bar app OBSERVES them and translates them into directional pause/resume of the currently
// playing YouTube tab via the existing Chrome-extension bridge.
//
// Why this lives here (cross-app, no shared framework): DistributedNotificationCenter is a system-
// wide name bus, so the only thing both apps must agree on is the exact notification-name string.
// These constants ARE that contract. The VoiceInk++ side hardcodes the same strings in
// RecordingActivityNotifier.swift — keep the two in sync if the names ever change.
//
// Payload: none required. The menu bar app already knows which YouTube tab is playing (from the
// extension's is-playing reports), so VoiceInk++ posts with no userInfo. We deliberately do NOT
// gate on VoiceInk's own "pause media while recording" toggle here — YouTube is the menu bar app's
// concern, complementary to VoiceInk's PlaybackController (which handles Spotify/Apple Music/
// MediaRemote). YouTube tabs the MediaRemote path can't reliably pause are covered by this path.
enum VoiceInkRecordingNotification {
  static let started = Notification.Name("com.ethansk.voiceink.recordingStarted")
  static let stopped = Notification.Name("com.ethansk.voiceink.recordingStopped")
  // A genuine Primary triple-click ends recorder ownership but deliberately preserves
  // whatever playback state exists at that instant. The bridge must decrement/reset
  // its dictation state without issuing `resume-youtube` or `pause-youtube`.
  static let stoppedPreservingPlayback = Notification.Name(
    "com.ethansk.voiceink.recordingStoppedPreservingPlayback"
  )
}

// Agentic Mouse browser-control IPC contract.
//
// AgenticMouse.app posts one of these no-payload DistributedNotificationCenter notifications for a
// physical YouTube scrub ratchet. The bridge owns Chrome/native-host relay and tab targeting, so
// Agentic Mouse never needs to focus Chrome or learn a tab id. The surface remains deliberately
// narrow: exactly five seconds backward or forward, never arbitrary page control.
enum AgenticMouseYouTubeNotification {
  static let jumpAhead = Notification.Name("com.ethansk.agenticmouse.youtube.jumpAhead")
  static let seekBackwardFiveSeconds = Notification.Name(
    "com.ethansk.agenticmouse.youtube.seekBackwardFiveSeconds"
  )
  static let seekBackwardFiveSecondsValue = -5.0
  static let seekForwardFiveSeconds = Notification.Name(
    "com.ethansk.agenticmouse.youtube.seekForwardFiveSeconds"
  )
  static let seekForwardFiveSecondsValue = 5.0

  static func seekSeconds(for name: Notification.Name) -> Double? {
    switch name {
    case seekBackwardFiveSeconds: return seekBackwardFiveSecondsValue
    case seekForwardFiveSeconds: return seekForwardFiveSecondsValue
    default: return nil
    }
  }

  static let volumeDecreaseFivePercent = Notification.Name(
    "com.ethansk.agenticmouse.youtube.volumeDecreaseFivePercent"
  )
  static let volumeIncreaseFivePercent = Notification.Name(
    "com.ethansk.agenticmouse.youtube.volumeIncreaseFivePercent"
  )
  static let volumeStep = 0.05

  static func volumeDelta(for name: Notification.Name) -> Double? {
    switch name {
    case volumeDecreaseFivePercent: return -volumeStep
    case volumeIncreaseFivePercent: return volumeStep
    default: return nil
    }
  }

  static let doubleSpeedHoldBegan = Notification.Name(
    "com.ethansk.agenticmouse.youtube.doubleSpeedHoldBegan"
  )
  static let doubleSpeedHoldRenewed = Notification.Name(
    "com.ethansk.agenticmouse.youtube.doubleSpeedHoldRenewed"
  )
  static let doubleSpeedHoldEnded = Notification.Name(
    "com.ethansk.agenticmouse.youtube.doubleSpeedHoldEnded"
  )
  static let holdTokenKey = "holdToken"
  static let restorePlaybackRateKey = "restorePlaybackRate"
  static let doubleSpeedValue = 2.0
  static let normalSpeedValue = 1.0
  static let holdLeaseMilliseconds = 2_500
}

enum AgenticMouseChromeTabHistoryNotification {
  static let back = Notification.Name(
    "com.ethansk.agenticmouse.chrome.tabHistoryBack"
  )
  static let forward = Notification.Name(
    "com.ethansk.agenticmouse.chrome.tabHistoryForward"
  )

  static func direction(for name: Notification.Name) -> String? {
    switch name {
      case back: return "back"
      case forward: return "forward"
      default: return nil
    }
  }
}

enum AgenticMouseChromeWebsite: String, CaseIterable {
  case youtube
  case x
  case facebook
  case github
  case linkedin
  case gemini
  case grok

  static let open = Notification.Name("com.ethansk.agenticmouse.chrome.openWebsite")
  static let websiteKey = "website"

  static func decode(_ notification: Notification) -> Self? {
    guard notification.name == open,
          let rawValue = notification.userInfo?[websiteKey] as? String
    else { return nil }
    return Self(rawValue: rawValue)
  }
}

enum BridgeNotification { // Previously YoutubeSpotifyMediaKeyShared.swift; keep these protocol names stable for Agent Flow, Agentic Mouse and spoken reminders.
  static let bridgeToApp = Notification.Name("com.ethan.youtubeSpotifyMediaKey.bridgeToApp")
  static let appToBridge = Notification.Name("com.ethan.youtubeSpotifyMediaKey.appToBridge")
  static let payloadKey = "payload"

  static func now() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
  }

  static func post(_ message: BridgeMessage, name: Notification.Name) {
    do {
      let payload = try JSONEncoder().encode(message)

      guard let json = String(data: payload, encoding: .utf8) else {
        log("Could not encode distributed bridge payload as UTF-8.")
        return
      }

      DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: [payloadKey: json],
        deliverImmediately: true,
      )
    } catch {
      log("Could not encode distributed bridge message: \(error)")
    }
  }

  static func decode(_ notification: Notification) -> BridgeMessage? {
    guard let json = notification.userInfo?[payloadKey] as? String,
          let data = json.data(using: .utf8)
    else {
      return nil
    }

    do {
      return try JSONDecoder().decode(BridgeMessage.self, from: data)
    } catch {
      log("Could not decode distributed bridge message: \(error)")
      return nil
    }
  }
}

// -- Unified log file + self-pruning ------------------------------------------------------------
//
// WHY this shape: every layer (menu-bar app, native host, and — funnelled via the native host's
// `client-log` — the Chrome extension) writes into ONE tailable file so the whole pause/resume chain
// interleaves in a single timeline. Ethan asked for "as much debug logging as we want" WITHOUT the
// file growing unbounded, so every line is stamped with an ISO8601 timestamp up front and the file
// self-prunes to a 30-day window (see pruneLog below). The timestamp MUST be the first token on the
// line so the pruner can parse it cheaply.
//
// logComponent identifies which binary emitted the line ("app" for the menu-bar app, "native-host"
// for the bridge host). Each binary sets this once at startup. Extension lines arrive through the
// native host already carrying their own `[ext:...]` sub-tag inside the message, so component=
// native-host + that sub-tag disambiguates all three sources.
var logComponent = "app"

private let logRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60 // 30 days — Ethan's requested window.
private let logURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/youtube-spotify-media-key.log")

// ISO8601 formatter with millisecond precision, reused (creating one per line is expensive and this
// runs on the hot logging path). Fractional seconds keep sub-second ordering visible for race debugging.
private let logTimestampFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

// Opportunistic-prune bookkeeping: prune every N writes so growth is bounded even between the daily
// timer ticks. Guarded by a lock because both the reader thread (native host stdin) and the main
// thread can call log().
private let logWriteLock = NSLock()
private var logWritesSincePrune = 0
private let logWritesBetweenPrunes = 4000

func log(_ message: String) {
  let timestamp = logTimestampFormatter.string(from: Date())
  let line = "\(timestamp) [\(logComponent)] \(message)\n"

  NSLog("%@", line.trimmingCharacters(in: .newlines))
  if !FileManager.default.fileExists(atPath: logURL.path) {
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
  }
  if let data = line.data(using: .utf8) {
    let descriptor = Darwin.open(logURL.path, O_WRONLY | O_APPEND) // Both helper processes append here; O_APPEND prevents one seek/write pair from overwriting the other.
    if descriptor >= 0 {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      handle.write(data)
      handle.closeFile()
    }
  }
  FileHandle.standardError.write(Data(line.utf8))

  // Opportunistic prune: cheap counter, occasional rewrite. Keeps the file bounded between the daily
  // scheduled prunes (e.g. a marathon dictation session that writes tens of thousands of lines).
  logWriteLock.lock()
  logWritesSincePrune += 1
  let shouldPrune = logWritesSincePrune >= logWritesBetweenPrunes
  if shouldPrune {
    logWritesSincePrune = 0
  }
  logWriteLock.unlock()

  if shouldPrune {
    pruneLog()
  }
}

// Drop every line older than the 30-day retention window and atomically rewrite the file. Robust by
// design because this runs unattended and must NEVER corrupt the log or crash a binary:
//   - Streams one line at a time, keeps a line if its leading ISO8601 timestamp parses AND is within the
//     window. Lines with NO parseable timestamp (legacy pre-timestamp backlog, or a rare multi-line
//     entry continuation) are kept ONLY if they fall in the tail safety window — this drops the huge
//     ancient timestampless backlog on the first run while never dropping recent context.
//   - Writes to a sibling temp file then atomically renames over the original, so a crash mid-write
//     leaves the original intact.
//   - Any failure is swallowed (best-effort): a pruning error must never take down logging itself.
func pruneLog() {
  guard let input = fopen(logURL.path, "r") else { return }
  defer { fclose(input) }
  var lineBuffer: UnsafeMutablePointer<CChar>?
  var lineCapacity = 0
  defer { free(lineBuffer) }

  // Count entries without retaining their text. The final empty entry still counts, matching the
  // previous split-on-newline behavior and its existing tail safety window.
  var totalCount = 0
  var endedWithNewline = false
  while true {
    let length = getline(&lineBuffer, &lineCapacity, input)
    if length < 0 { break }
    totalCount += 1
    if let lineBuffer { endedWithNewline = lineBuffer[length - 1] == 10 }
  }
  guard ferror(input) == 0, fseek(input, 0, SEEK_SET) == 0 else { return }
  if endedWithNewline { totalCount += 1 }

  // Tail safety window for timestampless lines: keep at most this many entries from the end. This
  // collapses the old timestampless backlog while keeping recent multi-line context.
  let tailKeepWindow = 3000
  let cutoff = Date().addingTimeInterval(-logRetentionSeconds)
  let tempURL = logURL.deletingLastPathComponent()
    .appendingPathComponent("youtube-spotify-media-key.log.prune-\(UUID().uuidString)")
  guard let output = fopen(tempURL.path, "w") else { return }
  defer {
    fclose(output)
    try? FileManager.default.removeItem(at: tempURL) // A read, write or replace failure leaves the original intact; discard only this unfinished output.
  }
  var index = 0
  var changed = false
  var retainedAnyLine = false
  var lastRetainedLineEndedWithNewline = true
  while true {
    let length = getline(&lineBuffer, &lineCapacity, input)
    if length < 0 { break }
    guard let lineBuffer else { return }
    let succeeded = autoreleasepool { // Release Foundation parsing objects per line, rather than retaining a whole log's temporary allocations.
      let isEmpty = length == 1 && lineBuffer[0] == 10
      let line = String(decoding: Data(bytes: lineBuffer, count: length), as: UTF8.self) // A torn UTF-8 body must not disable retention; retained bytes are copied unchanged below.
      let keep: Bool
      if isEmpty {
        keep = false
      } else if let timestamp = parseLeadingTimestamp(line) {
        keep = timestamp >= cutoff // Precise path: drop only entries older than the existing 30-day window.
      } else {
        keep = index >= totalCount - tailKeepWindow // No parseable timestamp: retain only recent-by-position context.
      }
      if keep {
        guard fwrite(lineBuffer, 1, length, output) == length else { return false }
        retainedAnyLine = true
        lastRetainedLineEndedWithNewline = lineBuffer[length - 1] == 10
      } else {
        changed = true
      }
      return true
    }
    guard succeeded else { return }
    index += 1
  }
  guard ferror(input) == 0, changed else { return } // Keeping everything must not rewrite the file or create an unnecessary replace window.
  if retainedAnyLine && !lastRetainedLineEndedWithNewline {
    guard fputc(10, output) != EOF else { return } // A rewritten file ends with one newline, as the previous join-and-append implementation did.
  }
  guard fflush(output) == 0 else { return }
  do {
    _ = try FileManager.default.replaceItemAt(logURL, withItemAt: tempURL) // Atomic replace: readers never observe a half-written log.
  } catch {
    return // Best-effort pruning never takes down logging; the deferred cleanup removes only the failed temporary output.
  }
}

// Parse the ISO8601 timestamp that log() writes as the first whitespace-delimited token. Returns nil
// for any line that doesn't start with a parseable timestamp (handled as "timestampless" by pruneLog).
private func parseLeadingTimestamp(_ line: String) -> Date? {
  guard let spaceIndex = line.firstIndex(of: " ") else {
    return nil
  }
  let token = String(line[line.startIndex..<spaceIndex])
  guard token.contains(".") else { return nil } // Preserve the existing fractional-second timestamp requirement.
  return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(token) // This Foundation value parser avoids the per-line Objective-C formatter cost on large logs.
}
