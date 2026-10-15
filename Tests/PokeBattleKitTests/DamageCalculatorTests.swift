import Testing
@testable import PokeBattleKit

/// Pins down the damage formula (level-50 stats, STAB, immunity, 4x
/// weaknesses, crits, burn, multi-hit) and the
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

    @Test("Damage follows the level-50 formula")
    func levelFiftyFormula() {
        // Base 80 everywhere is 100 Attack and 100 Defense at level 50, so a
        // 50-power STAB move does (22 * 50 * 100 / 100) / 50 + 2 = 24, x1.5.
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let tackle = Self.move(power: 50)
        #expect(attacker.attack == 100)
        #expect(DamageCalculator.estimateDamage(move: tackle, attacker: attacker, defender: defender, typeChart: Self.chart) == 36)
        let hit = DamageCalculator.computeDamage(
            power: 50, move: tackle, attacker: attacker, defender: defender, typeChart: Self.chart,
            forceCritical: false, roll: 1.0
        )
        #expect(hit.damage == 36)
    }

    @Test("A double weakness takes four times the damage")
    func doubleWeaknessIsUncapped() {
        let chart = TypeChart(attackers: [
            "fire": TypeMatchup(doubleDamageTo: ["grass", "bug"], halfDamageTo: [], noDamageTo: []),
        ])
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let neutral = Combatant(pokemon: Self.pokemon(types: ["normal"]), moves: [])
        let grassBug = Combatant(pokemon: Self.pokemon(types: ["grass", "bug"]), moves: [])
        let ember = Self.move(name: "ember", power: 40, damageClass: "special", typeName: "fire")
        let onNeutral = DamageCalculator.computeDamage(power: 40, move: ember, attacker: attacker, defender: neutral, typeChart: chart, forceCritical: false, roll: 1)
        let onWeak = DamageCalculator.computeDamage(power: 40, move: ember, attacker: attacker, defender: grassBug, typeChart: chart, forceCritical: false, roll: 1)
        #expect(onWeak.effectiveness == 4)
        // Truncation happens once at the end, so allow for the lost fraction.
        #expect(abs(onWeak.damage - onNeutral.damage * 4) <= 3)
    }

    @Test("A critical hit ignores the attacker's drops and the defender's boosts")
    func criticalIgnoresUnfavourableStages() {
        var attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        var defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let tackle = Self.move(power: 50)
        let clean = DamageCalculator.computeDamage(power: 50, move: tackle, attacker: attacker, defender: defender, typeChart: Self.chart, forceCritical: true, roll: 1)
        attacker.applyStage("attack", delta: -2)
        defender.applyStage("defense", delta: 2)
        let staged = DamageCalculator.computeDamage(power: 50, move: tackle, attacker: attacker, defender: defender, typeChart: Self.chart, forceCritical: true, roll: 1)
        #expect(staged.damage == clean.damage)
        #expect(clean.damage == Int(Double(36) * DamageCalculator.criticalMultiplier))
    }

    @Test("Crit chance is 1/24, rising with the move's crit stage", arguments: zip([0, 1, 2, 3], [1.0 / 24, 1.0 / 8, 0.5, 1.0]))
    func criticalChanceByStage(stage: Int, chance: Double) {
        #expect(DamageCalculator.criticalChance(stage: stage) == chance)
    }

    @Test("A burned attacker's physical damage estimate is halved")
    func burnHalvesPhysicalEstimate() {
        var attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let physical = Self.move(power: 80)
        let special = Self.move(name: "hyper-voice", power: 80, damageClass: "special")
        let healthy = DamageCalculator.estimateDamage(move: physical, attacker: attacker, defender: defender, typeChart: Self.chart)
        let healthySpecial = DamageCalculator.estimateDamage(move: special, attacker: attacker, defender: defender, typeChart: Self.chart)
        attacker.status = .burn
        #expect(DamageCalculator.estimateDamage(move: physical, attacker: attacker, defender: defender, typeChart: Self.chart) == healthy / 2)
        #expect(DamageCalculator.estimateDamage(move: special, attacker: attacker, defender: defender, typeChart: Self.chart) == healthySpecial)
    }

    @Test("Multi-hit moves are estimated at their expected hit count")
    func multiHitEstimate() {
        let attacker = Combatant(pokemon: Self.pokemon(), moves: [])
        let defender = Combatant(pokemon: Self.pokemon(), moves: [])
        let single = Self.move(name: "bullet", power: 25)
        let base = MoveSnapshot(from: single)
        let twoToFive = MoveSnapshot(
            name: "bullet-seed", displayName: "Bullet Seed", power: 25, accuracy: 100, priority: 0,
            damageClass: "physical", typeName: "normal", ailment: "none", ailmentChance: 0, drain: 0,
            healing: 0, effectChance: nil, statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false, minHits: 2, maxHits: 5
        )
        let perHit = DamageCalculator.estimateDamage(move: base, attacker: attacker, defender: defender, typeChart: Self.chart)
        let total = DamageCalculator.estimateDamage(move: twoToFive, attacker: attacker, defender: defender, typeChart: Self.chart)
        #expect(twoToFive.expectedHits == 3.1)
        #expect(abs(total - Int(Double(perHit) * 3.1)) <= 3)
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
