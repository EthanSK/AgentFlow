/*
============================================================
**MOVED FROM — MOVE HISTORY**
2026-11-24: RecorderTypedInputTests.swift,
RecorderTypedInputTests.waitForCompletion, task 01a1f045.
Shared by recorder HUD and Primary shortcut fixtures so their
main-actor handoff waits have one implementation. The follow-up
uses a monotonic deadline instead of a scheduler-attempt count.
============================================================
*/
import Foundation
import Testing

/// Extraction of existing RecorderTypedInputTests.waitForCompletion code,
/// now bounded by elapsed monotonic time rather than an iteration budget.
/// Wait for required main-actor work without changing any production timer.
@MainActor func waitForCompletion(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition(), "The expected recorder action did not complete")
}
