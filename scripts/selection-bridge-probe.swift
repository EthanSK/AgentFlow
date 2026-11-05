// Mini-only integration helper compiled alongside VSCodeSelectionBridge.swift.
// The test host contains synthetic fixtures only; never point this at live private editors.
import Foundation
import AppKit

@main struct SelectionBridgeProbe {
    static func main() async {
        guard [3, 4].contains(CommandLine.arguments.count),
              let pid = Int32(CommandLine.arguments[1]),
              let started = Double(CommandLine.arguments[2]) else { exit(2) }
        let context = CommandLine.arguments.count == 4 ? await VSCodeSelectionBridge.focusedContext(sourcePID: pid) : nil
        let text = await VSCodeSelectionBridge.read(
            sourcePID: pid, gestureStartedAt: Date(timeIntervalSince1970: started / 1000), context: context
        )
        let bounds: [String: Double]? = context?.bounds.map {
            ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["text": text as Any? ?? NSNull(),
            "surface": context?.surface as Any? ?? NSNull(), "bounds": bounds as Any? ?? NSNull(),
            "hostBundle": NSRunningApplication(processIdentifier: pid)?.bundleIdentifier as Any? ?? NSNull(),
            "hostLaunch": NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970 as Any? ?? NSNull()])
        print(String(decoding: data, as: UTF8.self))
    }
}
