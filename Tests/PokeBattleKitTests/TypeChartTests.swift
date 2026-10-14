import Testing
@testable import PokeBattleKit

/// Pins down type effectiveness lookups: single and dual defender types,
/// immunities, unknown attackers, and best-STAB selection.
@Suite("Type chart multiplier")
struct TypeChartTests {
    static let chart = TypeChart(attackers: [
        "fire": TypeMatchup(
            doubleDamageTo: ["grass", "ice"],
            halfDamageTo: ["water", "fire"],
            noDamageTo: []
        ),
        "water": TypeMatchup(
            doubleDamageTo: ["fire"],
            halfDamageTo: ["grass", "water"],
            noDamageTo: []
        ),
        "normal": TypeMatchup(
            doubleDamageTo: [],
            halfDamageTo: [],
            noDamageTo: ["ghost"]
        ),
    ])

    @Test(
        "Multiplier for attacking type against defender types",
        arguments: [
            (attacking: "fire", defenders: ["grass"], expected: 2.0),          // super effective
            (attacking: "fire", defenders: ["water"], expected: 0.5),          // not very effective
            (attacking: "normal", defenders: ["ghost"], expected: 0.0),        // immune
            (attacking: "fire", defenders: ["grass", "ice"], expected: 4.0),   // dual-type super effective
            (attacking: "fire", defenders: ["grass", "water"], expected: 1.0), // dual-type mixed
            (attacking: "fairy", defenders: ["fire"], expected: 1.0),          // unknown attacker is neutral
        ]
    )
    func multiplier(attacking: String, defenders: [String], expected: Double) {
        #expect(Self.chart.multiplier(attacking: attacking, defenders: defenders) == expected)
    }

    @Test(
        "Best STAB multiplier takes the maximum over attacker types",
        arguments: [
            // Fire/water vs grass: fire 2x, water 0.5x -> max 2.0
            (attackerTypes: ["fire", "water"], defenderTypes: ["grass"], expected: 2.0),
            // Normal vs ghost: 0x. Single type, max is still 0.
            (attackerTypes: ["normal"], defenderTypes: ["ghost"], expected: 0.0),
            // No attacker types -> neutral
            (attackerTypes: [], defenderTypes: ["grass"], expected: 1.0),
        ]
    )
    func bestSTABMultiplier(attackerTypes: [String], defenderTypes: [String], expected: Double) {
        let result = Self.chart.bestSTABMultiplier(attackerTypes: attackerTypes, defenderTypes: defenderTypes)
        #expect(result == expected)
    }
}
