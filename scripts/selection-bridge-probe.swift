// Mini-only integration helper compiled alongside VSCodeSelectionBridge.swift.
// The test host contains synthetic fixtures only; never point this at live private editors.
import Foundation

@main struct SelectionBridgeProbe {
    static func main() async {
        guard CommandLine.arguments.count == 3,
              let pid = Int32(CommandLine.arguments[1]),
              let started = Double(CommandLine.arguments[2]) else { exit(2) }
        let text = await VSCodeSelectionBridge.read(
            sourcePID: pid, gestureStartedAt: Date(timeIntervalSince1970: started / 1000)
        )
        let data = try! JSONSerialization.data(withJSONObject: ["text": text as Any? ?? NSNull()])
        print(String(decoding: data, as: UTF8.self))
    }
}
