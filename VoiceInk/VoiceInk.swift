import SwiftUI
import SwiftData
import AppKit
import OSLog
import AppIntents
import FluidAudio
import UserNotifications
import Sparkle
import Combine

@main
struct VoiceInkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    let container: ModelContainer

    @StateObject private var engine: VoiceInkEngine
    @StateObject private var whisperModelManager: WhisperModelManager
    @StateObject private var fluidAudioModelManager: FluidAudioModelManager
    @StateObject private var transcriptionModelManager: TranscriptionModelManager
    @StateObject private var recorderUIManager: RecorderUIManager
    @StateObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var newChatRecordingService: NewChatRecordingService
    @StateObject private var updaterViewModel: UpdaterViewModel
    @StateObject private var menuBarManager: MenuBarManager
    @StateObject private var aiService = AIService()
    @StateObject private var enhancementService: AIEnhancementService
    @StateObject private var activeWindowService = ActiveWindowService.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var showMenuBarIcon = true
    @State private var didShowAccessibilityReminder = false

    // Audio cleanup manager for automatic deletion of old audio files
    private let audioCleanupManager = AudioCleanupManager.shared

    // Transcription auto-cleanup service for zero data retention
    private let transcriptionAutoCleanupService = TranscriptionAutoCleanupService.shared

    // Model prewarm service for optimizing model on wake from sleep
    @StateObject private var prewarmService: ModelPrewarmService

    init() {
        // Disable HTTP response caching — prevents API responses from being stored in Cache.db
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)

        // Hold an app-lifetime activity assertion so macOS App Nap can't throttle our main
        // run loop while the Mac is idle. Without this the global record-hotkey CGEventTap
        // (whose run-loop source lives on the main run loop) gets disabled after a long idle
        // period, so the first press(es) after idle do nothing. See AppNapGuard for the full
        // explanation of the idle-miss bug. Must run first, before any heavy init work.
        _ = AppNapGuard.shared

        // App-lifetime gate also covers capture started during an already-speaking reminder.
        // It never changes manual Pause, session ownership, system mic volume or YouTube state.
        _ = CodexSpeechPlaybackReceiver.shared

        AppDefaults.registerDefaults()
        OnboardingV2Migration.prepareIfNeeded()

        let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "Initialization")
        // Keep existing model order stable; append new models after synced entities.
        let schema = Schema([
            Transcription.self,
            VocabularyWord.self,
            WordReplacement.self,
            SessionMetric.self
        ])
        let resolvedContainer: ModelContainer

        // Attempt 1: Try persistent storage
        do {
            resolvedContainer = try Self.createPersistentContainer(schema: schema, logger: logger)
        } catch let persistentError {
            // Attempt 2: Try in-memory storage
            do {
                resolvedContainer = try Self.createInMemoryContainer(schema: schema, logger: logger)
                logger.warning("Using in-memory storage as fallback. Data will not persist between sessions.")

                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Storage Warning")
                    alert.informativeText = String(localized: "Agent Flow couldn't access its storage location. Your transcriptions will not be saved between sessions.")
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: String(localized: "OK"))
                    alert.runModal()
                }
            } catch let memoryError {
                let persistentDetail = Self.fullErrorDescription(persistentError)
                let memoryDetail = Self.fullErrorDescription(memoryError)
                logger.critical("❌ All ModelContainer init attempts failed.\nPersistent:\n\(persistentDetail, privacy: .public)\nIn-memory:\n\(memoryDetail, privacy: .public)")
                fatalError("VoiceInk failed to initialize storage.\nPersistent:\n\(persistentDetail)\nIn-memory:\n\(memoryDetail)")
            }
        }

        container = resolvedContainer
        // Run before any retention/orphan cleanup starts. A force-quit can leave a
        // complete PCM payload whose ExtAudioFile header was never finalized; this
        // converts only our journaled PCM16 captures into recovery-pinned History rows.
        // It never resumes a provider, resolves an input, pastes, or sends text.
        let crashRecoverySummary = RecordingCrashRecoveryService.recoverPendingRecordings(
            modelContext: resolvedContainer.mainContext
        )
        DictionaryService.removeExactDuplicateContent(context: resolvedContainer.mainContext, source: "launch")

        // Initialize services with proper sharing of instances
        let aiService = AIService()
        _aiService = StateObject(wrappedValue: aiService)
        aiService.refreshOllamaAvailabilityInBackground()

        let updaterViewModel = UpdaterViewModel()
        _updaterViewModel = StateObject(wrappedValue: updaterViewModel)

        let enhancementService = AIEnhancementService(aiService: aiService, modelContext: resolvedContainer.mainContext)
        _enhancementService = StateObject(wrappedValue: enhancementService)

        // 1. Create modelsDirectory URL
        // Standalone-fork identity: Application Support folder keyed to the new bundle id so
        // VoiceInk++ stores its models/data separately from the official VoiceInk install.
        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus")
        let modelsDirectory = appSupportDirectory.appendingPathComponent("WhisperModels")

        // 2. Create model managers
        let whisperModelManager = WhisperModelManager(modelsDirectory: modelsDirectory)
        let fluidAudioModelManager = FluidAudioModelManager()
        let transcriptionModelManager = TranscriptionModelManager(
            whisperModelManager: whisperModelManager,
            fluidAudioModelManager: fluidAudioModelManager
        )

        // 3. Create UI manager
        let recorderUIManager = RecorderUIManager()

        // 4. Create engine
        let engine = VoiceInkEngine(
            modelContext: resolvedContainer.mainContext,
            whisperModelManager: whisperModelManager,
            transcriptionModelManager: transcriptionModelManager,
            enhancementService: enhancementService
        )

        CodexSpeechPlaybackReceiver.shared.configure { [weak engine] in
            engine.map { $0.blocksSpokenReminders }
        }

        // 5. Configure circular deps
        recorderUIManager.configure(engine: engine, recorder: engine.recorder)
        engine.recorderUIManager = recorderUIManager

        // 6. Initialize model state
        // Migration and refreshAllAvailableModels must run before loadCurrentTranscriptionModel so renamed keys are remapped and imported models are present when restoring the saved selection.
        StreamingKeysMigration.run()
        whisperModelManager.createModelsDirectoryIfNeeded()
        whisperModelManager.loadAvailableModels()
        transcriptionModelManager.refreshAllAvailableModels()
        transcriptionModelManager.loadCurrentTranscriptionModel()

        _whisperModelManager = StateObject(wrappedValue: whisperModelManager)
        _fluidAudioModelManager = StateObject(wrappedValue: fluidAudioModelManager)
        _transcriptionModelManager = StateObject(wrappedValue: transcriptionModelManager)
        _recorderUIManager = StateObject(wrappedValue: recorderUIManager)
        _engine = StateObject(wrappedValue: engine)

        // 7. Create other services that depend on engine
        let recordingShortcutManager = RecordingShortcutManager(engine: engine, recorderUIManager: recorderUIManager)
        _recordingShortcutManager = StateObject(wrappedValue: recordingShortcutManager)
        let newChatRecordingService = NewChatRecordingService(
            engine: engine, recorderUI: recorderUIManager
        )
        _newChatRecordingService = StateObject(wrappedValue: newChatRecordingService)

        let menuBarManager = MenuBarManager()
        _menuBarManager = StateObject(wrappedValue: menuBarManager)
        menuBarManager.configure(modelContainer: resolvedContainer, engine: engine)

        let activeWindowService = ActiveWindowService.shared
        _activeWindowService = StateObject(wrappedValue: activeWindowService)
        // Start observing frontmost-app changes so the active Mode FOLLOWS the app the
        // user switches into (issue #785). Without this, the Mode was only resolved at
        // record-start; Ethan starts recording first then clicks into the target app,
        // so the wrong app's auto-send behavior was applied. start() is idempotent.
        activeWindowService.start()

        let prewarmService = ModelPrewarmService(
            transcriptionModelManager: transcriptionModelManager,
            whisperModelManager: whisperModelManager,
            modelContext: resolvedContainer.mainContext
        )
        _prewarmService = StateObject(wrappedValue: prewarmService)

        appDelegate.menuBarManager = menuBarManager
        // Cooperative quits (including Codex's signed-app replacement flow) must
        // consult the live session collection before terminating. This prevents a
        // release restart from cutting off microphone audio or queued transcription.
        appDelegate.voiceInkEngine = engine
        appDelegate.newChatRecordingService = newChatRecordingService
        updaterViewModel.attach(to: appDelegate)

        // Ensure no lingering recording state from previous runs
        Task {
            await recorderUIManager.resetOnLaunch()
            if crashRecoverySummary.recoveredCount > 0 {
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "Recovered %d interrupted recording(s) in History"),
                        crashRecoverySummary.recoveredCount
                    ),
                    type: .info,
                    duration: 6
                )
            }
            if crashRecoverySummary.retainedForManualRecoveryCount > 0 {
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "%d interrupted recording(s) were kept for manual recovery"),
                        crashRecoverySummary.retainedForManualRecoveryCount
                    ),
                    type: .error,
                    playSound: false
                )
            }
        }

        AppShortcuts.updateAppShortcutParameters()

        let migrationTask = SessionMetricMigrationService.shared.runIfNeeded(modelContainer: resolvedContainer)
        let mainContext = resolvedContainer.mainContext
        Task {
            await migrationTask?.value
            TranscriptionAutoCleanupService.shared.startMonitoring(modelContext: mainContext)
        }
    }

    // MARK: - Container Creation Helpers

    private static func fullErrorDescription(_ error: Error, depth: Int = 0) -> String {
        let ns = error as NSError
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        lines.append("\(indent)[\(ns.domain) \(ns.code)] \(ns.localizedDescription)")
        for (key, value) in ns.userInfo {
            let keyStr = "\(key)"
            if keyStr == NSUnderlyingErrorKey || keyStr == "NSDetailedErrors" { continue }
            lines.append("\(indent)  \(keyStr): \(value)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("\(indent)  Underlying:")
            lines.append(fullErrorDescription(underlying, depth: depth + 2))
        }
        if let details = ns.userInfo["NSDetailedErrors"] as? [Error] {
            lines.append("\(indent)  DetailedErrors (\(details.count)):")
            for (i, detail) in details.enumerated() {
                lines.append("\(indent)    [\(i)]:")
                lines.append(fullErrorDescription(detail, depth: depth + 3))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func createPersistentContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        // Standalone-fork identity: SwiftData store lives under the new bundle id's Application
        // Support folder so VoiceInk++ never shares its DB with the official VoiceInk.
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ethansk.VoiceInkPlusPlus", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let defaultStoreURL = appSupportURL.appendingPathComponent("default.store")
        let dictionaryStoreURL = appSupportURL.appendingPathComponent("dictionary.store")
        let statsStoreURL = appSupportURL.appendingPathComponent("stats.store")

        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration(
            "default",
            schema: transcriptSchema,
            url: defaultStoreURL,
            cloudKitDatabase: .none
        )

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        #if LOCAL_BUILD
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .none
        #else
        // iCloud container intentionally left as the upstream id — it must match a PROVISIONED
        // CloudKit container in the Apple Developer account, and we haven't created a new one.
        // This branch only runs in signed (non-LOCAL_BUILD) builds; Ethan's `make local` path uses
        // the .none branch above, so the old id is inert for his standalone VoiceInk++ build.
        let dictionaryCloudKit: ModelConfiguration.CloudKitDatabase = .private("iCloud.com.prakashjoshipax.VoiceInk")
        #endif
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: dictionarySchema,
            url: dictionaryStoreURL,
            cloudKitDatabase: dictionaryCloudKit
        )

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration(
            "stats",
            schema: statsSchema,
            url: statsStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create persistent ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    private static func createInMemoryContainer(schema: Schema, logger: Logger) throws -> ModelContainer {
        let transcriptSchema = Schema([Transcription.self])
        let transcriptConfig = ModelConfiguration("default", schema: transcriptSchema, isStoredInMemoryOnly: true)

        let dictionarySchema = Schema([VocabularyWord.self, WordReplacement.self])
        let dictionaryConfig = ModelConfiguration("dictionary", schema: dictionarySchema, isStoredInMemoryOnly: true)

        let statsSchema = Schema([SessionMetric.self])
        let statsConfig = ModelConfiguration("stats", schema: statsSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig)
        } catch {
            logger.error("❌ Failed to create in-memory ModelContainer:\n\(Self.fullErrorDescription(error), privacy: .public)")
            throw error
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboardingV2 {
                    ContentView()
                        .environmentObject(engine)
                        .environmentObject(whisperModelManager)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(transcriptionModelManager)
                        .environmentObject(recorderUIManager)
                        .environmentObject(recordingShortcutManager)
                        .environmentObject(updaterViewModel)
                        .environmentObject(menuBarManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .modelContainer(container)
                        .onAppear {
                            showAccessibilityReminderIfNeeded()

                            // Start the automatic audio cleanup process only if transcript cleanup is not enabled
                            if !UserDefaults.standard.bool(forKey: "IsTranscriptionCleanupEnabled") {
                                audioCleanupManager.startAutomaticCleanup(modelContext: container.mainContext)
                            }

                            // Process any pending open-file request now that the main ContentView is ready.
                            if let pendingURL = appDelegate.pendingOpenFileURL {
                                NotificationCenter.default.post(name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": pendingURL])
                                }
                                appDelegate.pendingOpenFileURL = nil
                            }
                        }
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                        .onDisappear {
                            whisperModelManager.unloadModel()

                            // Stop the automatic audio cleanup process
                            audioCleanupManager.stopAutomaticCleanup()
                        }
                } else {
                    OnboardingView(hasCompletedOnboardingV2: $hasCompletedOnboardingV2)
                        .environmentObject(fluidAudioModelManager)
                        .environmentObject(aiService)
                        .environmentObject(enhancementService)
                        .frame(width: 950)
                        .frame(minHeight: 730)
                        .background(WindowAccessor { window in
                            WindowManager.shared.configureWindow(window)
                        })
                }
            }
            .modifier(MainWindowZoom())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: MainWindowLayout.minimumSize.width,
                     height: MainWindowLayout.minimumSize.height)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .toolbar) {
                Divider()
                MainWindowZoomMenu(keyboardShortcuts: true)
            }

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updaterViewModel: updaterViewModel)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(whisperModelManager)
                .environmentObject(fluidAudioModelManager)
                .environmentObject(transcriptionModelManager)
                .environmentObject(recorderUIManager)
                .environmentObject(recordingShortcutManager)
                .environmentObject(menuBarManager)
                .environmentObject(updaterViewModel)
                .environmentObject(aiService)
                .environmentObject(enhancementService)
        } label: {
            let image: NSImage = {
                let ratio = $0.size.height / $0.size.width
                $0.size.height = 22
                $0.size.width = 22 / ratio
                return $0
            }(NSImage(named: "menuBarIcon")!)

            Image(nsImage: image)
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
        WindowGroup("Debug") {
            Button("Toggle Menu Bar Only") {
                menuBarManager.isMenuBarOnly.toggle()
            }
        }
        #endif
    }

    private func showAccessibilityReminderIfNeeded() {
        guard !didShowAccessibilityReminder else { return }
        didShowAccessibilityReminder = true

        guard !AXIsProcessTrusted() else { return }

        NotificationManager.shared.showNotification(
            title: String(localized: "Accessibility permission is not provided"),
            type: .warning,
            duration: 7.0,
            actionButton: (String(localized: "Open Settings"), Self.openAccessibilitySettings)
        )
    }

    private static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AgentFlowRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft, prerelease
    }
}

enum AgentFlowUpdatePolicy {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/EthanSK/AgentFlow/releases/latest"
    )!

    // Public tags combine the marketing version and independent app build (v2.0.398).
    // Comparing only 2.0 would offer an older public build to a newer local install.
    static func installedReleaseTag(version: String?, build: String?) -> String? {
        guard let version, let build, !build.isEmpty,
              build.allSatisfy({ $0.isASCII && $0.isNumber }),
              versionComponents(version) != nil else { return nil }
        let tag = "v\(version).\(build)"
        return versionComponents(tag) == nil ? nil : tag
    }

    static func isOwnReleaseURL(_ url: URL, tag: String) -> Bool {
        guard versionComponents(tag) != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return components.scheme == "https"
            && components.host == "github.com"
            && components.port == nil && components.user == nil && components.password == nil
            && components.query == nil && components.fragment == nil
            && components.path == "/EthanSK/AgentFlow/releases/tag/\(tag)"
    }

    static func isPublishedOwnRelease(_ release: AgentFlowRelease) -> Bool {
        !release.draft && !release.prerelease
            && isOwnReleaseURL(release.htmlURL, tag: release.tagName)
    }

    static func isAutomaticCheckDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticCheckInterval
    }

    static func isNewerRelease(_ releaseTag: String, than installedTag: String) -> Bool {
        guard let release = versionComponents(releaseTag),
              let installed = versionComponents(installedTag) else { return false }
        for index in 0..<max(release.count, installed.count) {
            let candidate = index < release.count ? release[index] : 0
            let current = index < installed.count ? installed[index] : 0
            if candidate != current { return candidate > current }
        }
        return false
    }

    static func shouldNotify(
        releaseTag: String,
        installedTag: String,
        lastNotifiedTag: String?,
        checksEnabled: Bool
    ) -> Bool {
        checksEnabled
            && releaseTag != lastNotifiedTag
            && isNewerRelease(releaseTag, than: installedTag)
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.first == "v" || trimmed.first == "V"
            ? String(trimmed.dropFirst()) : trimmed
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({
            !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && Int($0) != nil
        }) else { return nil }
        return parts.compactMap { Int($0) }
    }
}

final class AgentFlowUpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private static let releaseURLKey = "agentFlowReleaseURL"
    private static let releaseTagKey = "agentFlowReleaseTag"

    static func content(for release: AgentFlowRelease) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "There’s an Agent Flow update"
        content.body = "\(release.tagName) is available. Open the release to download it."
        content.sound = .default
        content.userInfo = [releaseURLKey: release.htmlURL.absoluteString, releaseTagKey: release.tagName]
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard
            let value = response.notification.request.content.userInfo[Self.releaseURLKey] as? String,
            let tag = response.notification.request.content.userInfo[Self.releaseTagKey] as? String,
            let url = URL(string: value),
            AgentFlowUpdatePolicy.isOwnReleaseURL(url, tag: tag)
        else {
            return
        }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}

// Sparkle supplies the standard update dialog, signature validation and installer.
// Ethan's daily-check preference survives the notification-only updater migration.
@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let automaticChecksKey = "VIPPDailyUpdateChecksEnabled"
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    private var controller: SPUStandardUpdaterController?
    private weak var appDelegate: AppDelegate?
    private var observations = Set<AnyCancellable>()

    override init() {
        super.init()
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil {
            defaults.set(defaults.bool(forKey: Self.automaticChecksKey), forKey: "SUEnableAutomaticChecks")
        }
        // Source-only builds without a production verification key cannot offer
        // unverified downloads. The release packager requires this key to match.
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.updateCheckInterval = AgentFlowUpdatePolicy.automaticCheckInterval
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }.store(in: &observations)
        controller.startUpdater()
    }

    func attach(to appDelegate: AppDelegate) { self.appDelegate = appDelegate }
    func checkForUpdates() { if canCheckForUpdates { controller?.checkForUpdates(nil) } }
    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.automaticChecksKey)
        controller?.updater.automaticallyChecksForUpdates = value
    }
    func setAutomaticallyDownloadsUpdates(_ value: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = value
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // The same all-session boundary used by an attended installation owns
        // microphone starts, transcriptions, History retries and pending delivery.
        appDelegate?.installUpdateWhenIdle(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        appDelegate?.cancelPendingUpdateInstallation()
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
