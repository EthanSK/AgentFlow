// Optional Agent Flow OBS reply timestamp. Inserted by install.py into the
// existing shared speaker; it observes only the already-owned audio child.
// Date is for audit and systemUptime is for mapping onto OBS's live clock.
if let receiptPath = ProcessInfo.processInfo.environment["AGENTFLOW_OBS_PLAYBACK_RECEIPT"],
   receiptPath.hasPrefix("/"), receiptPath.hasSuffix("/playback-end.json") {
    speech.terminationHandler = { finished in
        let endedWall = Date().timeIntervalSince1970
        let endedUptime = ProcessInfo.processInfo.systemUptime
        let observation: [String: Any] = ["endedWall": endedWall, "endedUptime": endedUptime,
            "returncode": Int(finished.terminationStatus),
            "reason": finished.terminationReason == .exit ? "exit" : "signal",
            "timestampMeaning": "Observed audio-child exit; physical speaker latency is not measured"]
        if let data = try? JSONSerialization.data(withJSONObject: observation) {
            try? data.write(to: URL(fileURLWithPath: receiptPath), options: .atomic)
            _ = chmod(receiptPath, S_IRUSR | S_IWUSR)
        }
    }
}

func publishOBSReplyPlaybackStart() {
    let environment = ProcessInfo.processInfo.environment
    guard let latest = environment["AGENTFLOW_OBS_LATEST_FILE"], latest.hasPrefix("/"),
          let eventID = environment["AGENTFLOW_OBS_EVENT_ID"], UUID(uuidString: eventID) != nil else { return }
    if let data = try? JSONSerialization.data(withJSONObject: ["eventID": eventID,
        "startedUptime": ProcessInfo.processInfo.systemUptime]) {
        try? data.write(to: URL(fileURLWithPath: latest), options: .atomic)
        _ = chmod(latest, S_IRUSR | S_IWUSR)
    }
}
