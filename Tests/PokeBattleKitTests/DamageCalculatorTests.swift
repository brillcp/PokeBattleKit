import Testing
@testable import PokeBattleKit

/// Pins down damage estimation (STAB, immunity, super-effective cap) and the
/// move-selection helpers built on it (`guaranteedKO`, `strongestMove`).
@Suite("Damage calculator")
struct DamageCalculatorTests {
    static let chart = TypeChart(attackers: [
        "fire": TypeMatchup(doubleDamageTo: ["grass"], halfDamageTo: ["water"], noDamageTo: []),
        "water": TypeMatchup(doubleDamageTo: ["fire"], halfDamageTo: ["grass"], noDamageTo: []),
        "normal": TypeMatchup(doubleDamageTo: [], halfDamageTo: [], noDamageTo: ["ghost"]),
        "electric": TypeMatchup(doubleDamageTo: ["water"], halfDamageTo: [], noDamageTo: ["ground"]),
    ])

    static func pokemon(
        name: String = "Test",
        types: [String] = ["normal"],
        stats: [String: Int] = ["hp": 80, "attack": 80, "defense": 80, "special-attack": 80, "special-defense": 80, "speed": 80]
    ) -> TestPokemon {
        TestPokemon(id: 1, name: name, frontSprite: "", backSprite: nil, typeNames: types, statLookup: stats)
    }

    static func move(
        name: String = "tackle",
        power: Int? = 50,
        damageClass: String = "physical",
        typeName: String = "normal",
        accuracy: Int? = 100
    ) -> MoveSnapshot {
        MoveSnapshot(
            name: name, displayName: name.capitalized, power: power, accuracy: accuracy,
            priority: 0, damageClass: damageClass, typeName: typeName,
            ailment: "none", ailmentChance: 0, drain: 0, healing: 0, effectChance: nil,
            statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false
        )
    }

    @Test("Super-effective damaging move estimates positive damage")
    func estimatePositiveDamage() {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["grass"]), moves: [])
        let m = Self.move(name: "flamethrower", power: 90, damageClass: "special", typeName: "fire")
        let dmg = DamageCalculator.estimateDamage(move: m, attacker: attacker, defender: defender, typeChart: Self.chart)
        #expect(dmg > 0)
    }

    @Test("STAB boosts estimated damage")
    func estimateSTABBoosts() {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["normal"]), moves: [])
        let stab = Self.move(name: "ember", power: 40, damageClass: "special", typeName: "fire")
        let noStab = Self.move(name: "tackle", power: 40, damageClass: "special", typeName: "normal")
        let stabDmg = DamageCalculator.estimateDamage(move: stab, attacker: attacker, defender: defender, typeChart: Self.chart)
        let noStabDmg = DamageCalculator.estimateDamage(move: noStab, attacker: attacker, defender: defender, typeChart: Self.chart)
        #expect(stabDmg > noStabDmg)
    }

    @Test("Immune defender takes zero estimated damage")
    func estimateImmunityReturnsZero() {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["normal"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["ghost"]), moves: [])
        let m = Self.move(name: "tackle", power: 50, typeName: "normal")
        let dmg = DamageCalculator.estimateDamage(move: m, attacker: attacker, defender: defender, typeChart: Self.chart)
        #expect(dmg == 0)
    }

    @Test("Status move estimates zero damage")
    func estimateStatusMoveReturnsZero() {
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let m = Self.move(name: "thunder-wave", power: nil, damageClass: "status", typeName: "electric")
        let dmg = DamageCalculator.estimateDamage(move: m, attacker: attacker, defender: defender, typeChart: Self.chart)
        #expect(dmg == 0)
    }

    @Test("Super-effective cap lowers estimated damage")
    func superEffectiveCapped() {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["electric"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["water"]), moves: [])
        let m = Self.move(name: "thunderbolt", power: 90, damageClass: "special", typeName: "electric")
        let capped = DamageCalculator.estimateDamage(move: m, attacker: attacker, defender: defender, typeChart: Self.chart, superEffectiveCap: 1.5)
        let uncapped = DamageCalculator.estimateDamage(move: m, attacker: attacker, defender: defender, typeChart: Self.chart, superEffectiveCap: 4.0)
        #expect(capped < uncapped)
    }

    @Test("Guaranteed KO finds a move that knocks out the defender")
    func guaranteedKOFindsKiller() throws {
        var defender = Combatant(pokemon: Self.pokemon(types: ["grass"]), moves: [])
        defender.currentHP = 5
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let killer = Self.move(name: "flamethrower", power: 90, damageClass: "special", typeName: "fire")
        let result = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender, moves: [killer], typeChart: Self.chart
        )
        let move = try #require(result)
        #expect(move.name == "flamethrower")
    }

    @Test("Guaranteed KO is nil when every move is too weak")
    func guaranteedKONilWhenAllTooWeak() {
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let weak = Self.move(name: "tackle", power: 10)
        let result = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender, moves: [weak], typeChart: Self.chart
        )
        #expect(result == nil)
    }

    @Test("Guaranteed KO skips moves below the accuracy floor")
    func guaranteedKOSkipsBelowAccuracyFloor() {
        var defender = Combatant(pokemon: Self.pokemon(types: ["grass"]), moves: [])
        defender.currentHP = 5
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let inaccurate = Self.move(
            name: "fire-blast", power: 110, damageClass: "special", typeName: "fire", accuracy: 50
        )
        let result = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender, moves: [inaccurate], typeChart: Self.chart
        )
        #expect(result == nil)
    }

    @Test("Guaranteed KO picks the move with higher expected damage")
    func guaranteedKOPicksHigherExpectedDamage() throws {
        var defender = Combatant(pokemon: Self.pokemon(types: ["grass"]), moves: [])
        defender.currentHP = 5
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let weakerAccurate = Self.move(
            name: "ember", power: 40, damageClass: "special", typeName: "fire", accuracy: 100
        )
        let strongerSlightlyLessAccurate = Self.move(
            name: "flamethrower", power: 90, damageClass: "special", typeName: "fire", accuracy: 90
        )
        // Both KO 5 HP. flamethrower's accuracy-weighted dmg dwarfs ember's.
        let result = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender,
            moves: [weakerAccurate, strongerSlightlyLessAccurate],
            typeChart: Self.chart
        )
        let move = try #require(result)
        #expect(move.name == "flamethrower")
    }

    @Test("Strongest move returns the highest-damage move")
    func strongestMoveReturnsHighestDamage() throws {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["fire"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["grass"]), moves: [])
        let weak = Self.move(name: "ember", power: 40, damageClass: "special", typeName: "fire")
        let strong = Self.move(name: "flamethrower", power: 90, damageClass: "special", typeName: "fire")
        let result = try #require(DamageCalculator.strongestMove(
            attacker: attacker, defender: defender, moves: [weak, strong], typeChart: Self.chart
        ))
        #expect(result.move.name == "flamethrower")
        #expect(result.damage > 0)
    }

    @Test("Strongest move is nil when the defender is immune to every move")
    func strongestMoveNilWhenAllImmune() {
        let attacker = Combatant(pokemon: Self.pokemon(types: ["normal"]), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(types: ["ghost"]), moves: [])
        let m = Self.move(name: "tackle", power: 50, typeName: "normal")
        let result = DamageCalculator.strongestMove(
            attacker: attacker, defender: defender, moves: [m], typeChart: Self.chart
        )
        #expect(result == nil)
    }

    @Test("Strongest move is nil when only status moves are available")
    func strongestMoveNilWhenOnlyStatusMoves() {
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let m = Self.move(name: "growl", power: nil, damageClass: "status")
        let result = DamageCalculator.strongestMove(
            attacker: attacker, defender: defender, moves: [m], typeChart: Self.chart
        )
        #expect(result == nil)
    }
}

struct TestPokemon: PokemonData {
    let id: Int
    let name: String
    let frontSprite: String
    let backSprite: String?
    let typeNames: [String]
    let statLookup: [String: Int]
}
