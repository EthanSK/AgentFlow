#!/usr/bin/swift
// Explicit one-shot Agent Flow control. Never launches the app or changes capture.
import AppKit
import Foundation
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.ethansk.VoiceInkPlusPlus")
guard apps.count == 1, let app = apps.first,
      app.bundleURL?.path == "/Applications/AgentFlow.app" else {
    fputs("One installed Agent Flow instance is required.\n", stderr); exit(2)
}
let speechID = UUID().uuidString
let center = DistributedNotificationCenter.default()
var acknowledged = false
let observer = center.addObserver(forName: .init("com.ethansk.codex.speechPlaybackAck"), object: nil, queue: .main) { note in
    guard let raw = note.userInfo?["payload"] as? String, raw.utf8.count <= 2048,
          let data = raw.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          value["speechID"] as? String == speechID,
          value["appPID"] as? Int32 == app.processIdentifier,
          value["version"] as? Int == 3, value["mode"] as? String == "idle-only",
          value["type"] as? String == "override-ack",
          value["playbackAllowed"] as? Bool == true else { return }
    acknowledged = true
}
let payload: [String: Any] = ["version": 3, "mode": "idle-only", "type": "allow-next",
    "speechID": speechID, "pid": getpid(), "reason": "codex-spoken-reminder"]
let data = try JSONSerialization.data(withJSONObject: payload)
center.postNotificationName(.init("com.ethansk.codex.speechPlayback"), object: nil,
    userInfo: ["payload": String(decoding: data, as: UTF8.self)], deliverImmediately: true)
let deadline = Date().addingTimeInterval(1)
while !acknowledged && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
}
center.removeObserver(observer)
guard acknowledged else { fputs("Agent Flow did not acknowledge the one-shot override.\n", stderr); exit(3) }
print("{\"armed\":true,\"expires_in_seconds\":30}")
