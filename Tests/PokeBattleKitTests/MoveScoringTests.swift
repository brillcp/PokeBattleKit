import Testing
@testable import PokeBattleKit

/// Pins down in-battle move scoring heuristics: low-HP preferences and
/// escalating penalties for repeating the same move.
@Suite("Move scoring")
struct MoveScoringTests {

    static let chart = TypeChart(attackers: [
        "normal": TypeMatchup(doubleDamageTo: [], halfDamageTo: [], noDamageTo: ["ghost"]),
        "fairy":  TypeMatchup(doubleDamageTo: ["dragon", "dark", "fighting"], halfDamageTo: ["fire", "poison", "steel"], noDamageTo: []),
    ])

    static func pokemon(
        types: [String] = ["normal"],
        hp: Int = 100,
        hpFraction: Double? = nil,
        attack: Int = 80,
        specialAttack: Int = 80,
        speed: Int = 80
    ) -> Combatant {
        let stats: [String: Int] = [
            "hp": hp, "attack": attack, "defense": 80,
            "special-attack": specialAttack, "special-defense": 80, "speed": speed
        ]
        var c = Combatant(pokemon: TestPokemon(
            id: 1, name: "test", frontSprite: "", backSprite: nil,
            typeNames: types, statLookup: stats
        ), moves: [])
        if let hpFraction { c.currentHP = Int(Double(c.maxHP) * hpFraction) }
        return c
    }

    static func damageMove(
        name: String = "tackle",
        power: Int = 80,
        typeName: String = "normal",
        priority: Int = 0,
        accuracy: Int = 100
    ) -> MoveSnapshot {
        MoveSnapshot(
            name: name, displayName: name, power: power, accuracy: accuracy,
            priority: priority, damageClass: "physical", typeName: typeName,
            ailment: "none", ailmentChance: 0, drain: 0, healing: 0, effectChance: nil,
            statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false
        )
    }

    static func boostMove(name: String = "swords-dance") -> MoveSnapshot {
        MoveSnapshot(
            name: name, displayName: name, power: nil, accuracy: nil,
            priority: 0, damageClass: "status", typeName: "normal",
            ailment: "none", ailmentChance: 0, drain: 0, healing: 0, effectChance: nil,
            statChangeNames: ["attack"], statChangeDeltas: [2],
            isRechargeMove: false, hasSelfDebuff: false
        )
    }

    // MARK: - Low-HP behaviour

    @Test("At low HP, damaging move scores higher than a stat-boost")
    func lowHP_damageBeatsBoost() {
        let attacker = Self.pokemon(hp: 100, hpFraction: 0.05)  // in KO range
        let defender = Self.pokemon()
        let damage = Self.damageMove()
        let boost  = Self.boostMove()

        let dScore = MoveScoring.inBattleScore(
            move: damage, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: [damage.name]
        )
        let bScore = MoveScoring.inBattleScore(
            move: boost, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: []
        )
        #expect(dScore > bScore, "Damage move (\(dScore)) should beat boost (\(bScore)) at low HP")
    }

    @Test("At low HP, priority move scores higher than normal-speed move")
    func lowHP_priorityBonus() {
        let attacker = Self.pokemon(hp: 100, hpFraction: 0.05)  // in KO range
        let defender = Self.pokemon()
        let normal   = Self.damageMove(name: "tackle", priority: 0)
        let priority = Self.damageMove(name: "quick-attack", priority: 1)

        let nScore = MoveScoring.inBattleScore(
            move: normal, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: []
        )
        let pScore = MoveScoring.inBattleScore(
            move: priority, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: []
        )
        #expect(pScore > nScore, "Priority move (\(pScore)) should beat normal move (\(nScore)) at low HP")
    }

    @Test("At full HP, stat-boost can outscore a weak damage move")
    func fullHP_boostCanWin() {
        let attacker = Self.pokemon(hp: 100)
        let defender = Self.pokemon()
        let damage = Self.damageMove(power: 20)  // low power → STAB score still < boost
        let boost  = Self.boostMove()

        let dScore = MoveScoring.inBattleScore(
            move: damage, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: []
        )
        let bScore = MoveScoring.inBattleScore(
            move: boost, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: []
        )
        #expect(bScore > dScore, "Boost (\(bScore)) should beat weak damage (\(dScore)) at full HP")
    }

    // MARK: - Recency penalties

    /// Each case compares a move used `priorUses` times in a row against the
    /// same move used once more (0 vs 1, 1 vs 2, 2 vs 3 consecutive uses).
    @Test("Consecutive use penalty escalates with each repeat", arguments: 0...2)
    func recencyEscalation(priorUses: Int) {
        let attacker = Self.pokemon()
        let defender = Self.pokemon()
        let move = Self.damageMove()

        let fewer = MoveScoring.inBattleScore(
            move: move, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: Array(repeating: move.name, count: priorUses)
        )
        let more = MoveScoring.inBattleScore(
            move: move, attacker: attacker, defender: defender,
            typeChart: Self.chart, recentMoves: Array(repeating: move.name, count: priorUses + 1)
        )
        #expect(fewer > more, "Used \(priorUses + 1)x (\(more)) should score less than \(priorUses)x (\(fewer))")
    }
}
