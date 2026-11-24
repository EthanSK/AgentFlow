/*
============================================================
**MOVED FROM — MOVE HISTORY**
2026-11-24: RecorderTypedInputTests.swift,
RecorderTypedInputTests.waitForCompletion, task 01a1f045.
Shared by recorder HUD and Primary shortcut fixtures so their
main-actor handoff waits have one implementation. This first
move preserves the existing bounded-attempt behavior.
============================================================
*/
import Foundation
import Testing

/// Extraction of existing RecorderTypedInputTests.waitForCompletion code.
/// Wait for required main-actor work without changing any production timer.
@MainActor func waitForCompletion(_ condition: () -> Bool) async throws {
    for _ in 0..<400 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "The expected recorder action did not complete")
}
