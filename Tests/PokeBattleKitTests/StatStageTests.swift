import Testing
@testable import PokeBattleKit

/// Pins down the stat stage multiplier table, including clamping to the
/// -6...+6 stage range.
@Suite("Stat stage multiplier")
struct StatStageTests {
    @Test(
        "Stage maps to its exact multiplier",
        arguments: [
            (stage: 0, expected: 1.0),   // neutral
            (stage: 6, expected: 4.0),   // max boost
            (stage: -6, expected: 0.25), // max drop
            (stage: 1, expected: 1.5),
        ]
    )
    func exactMultiplier(stage: Int, expected: Double) {
        #expect(statStageMultiplier(stage) == expected)
    }

    @Test(
        "Stages beyond the range clamp to the nearest limit",
        arguments: [
            (stage: 10, limit: 6),
            (stage: -10, limit: -6),
        ]
    )
    func clampsToLimit(stage: Int, limit: Int) {
        #expect(statStageMultiplier(stage) == statStageMultiplier(limit))
    }

    @Test("Stage -1 is two thirds")
    func minusOneIsTwoThirds() {
        let result = statStageMultiplier(-1)
        #expect(abs(result - 2.0 / 3.0) < 0.001)
    }
}
