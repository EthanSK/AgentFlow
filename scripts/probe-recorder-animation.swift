// Disposable hosted AppKit diagnosis; never run against Ethan's live app. — GPT-6.1 Sol
import AppKit
import QuartzCore
import Foundation
import Darwin

@MainActor final class CompletionState { var finished = false }

@MainActor func observe(_ panel: NSPanel, started: Double,
                        rows: inout [[Double]], maxGap: inout Double,
                        last: inout Double) {
    let now = CACurrentMediaTime()
    maxGap = max(maxGap, now - last)
    last = now
    let alpha = Double(panel.alphaValue)
    if rows.isEmpty || abs((rows.last?.last ?? 2) - alpha) > 0.005 {
        if rows.count < 64 { rows.append([now - started, alpha]) }
    }
}

@MainActor func spinOneTurn() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
}

@MainActor func runProbe(strategy: String) async throws {
    let app = NSApplication.shared
    if strategy == "active-async" { app.activate(ignoringOtherApps: true) }
    let panel = NSPanel(contentRect: NSRect(x: 60, y: 100, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .black
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.orderFrontRegardless()
    panel.displayIfNeeded()
    defer { panel.orderOut(nil); panel.close() }
    try await Task.sleep(for: .milliseconds(150))
    let state = CompletionState()
    let started = CACurrentMediaTime()
    var rows: [[Double]] = [[0, Double(panel.alphaValue)]]
    var last = started
    var maxGap = 0.0
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.22
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        panel.animator().alphaValue = 0
    }, completionHandler: { Task { @MainActor in state.finished = true } })
    if strategy == "flush" { CATransaction.flush() }
    while CACurrentMediaTime() - started < 1 {
        observe(panel, started: started, rows: &rows, maxGap: &maxGap, last: &last)
        if strategy == "async" || strategy == "active-async" {
            try await Task.sleep(for: .milliseconds(2))
        } else {
            spinOneTurn()
        }
    }
    let finishedBeforeYield = state.finished
    try await Task.sleep(for: .milliseconds(100))
    let result: [String: Any] = [
        "requestedPolicy": CommandLine.arguments[2], "strategy": strategy,
        "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        "appRunning": app.isRunning, "appActive": app.isActive,
        "interpolated": rows.contains { $0[1] > 0 && $0[1] < 1 },
        "contentSampleBand": rows.contains { $0[1] > 0.1 && $0[1] < 0.6 },
        "finishedBeforeYield": finishedBeforeYield, "finishedAfterYield": state.finished,
        "maxSampleGapMS": maxGap * 1000, "timeline": rows
    ]
    print("RecorderAnimationProbe " + String(data: try JSONSerialization.data(withJSONObject: result,
        options: [.sortedKeys]), encoding: .utf8)!)
}

guard CommandLine.arguments.count == 3,
      ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
    print("This disposable probe requires the GitHub-hosted diagnostic job and two arguments.")
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    do { try await runProbe(strategy: CommandLine.arguments[1]) }
    catch { print("RecorderAnimationProbe error=\(error)"); exit(1) }
    app.terminate(nil)
}
app.run()
