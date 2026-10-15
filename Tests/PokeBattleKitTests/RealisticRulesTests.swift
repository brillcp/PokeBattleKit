import Foundation
import Testing
@testable import PokeBattleKit

/// Pins down the main-series rules added on top of the basic engine:
/// level-50 stats, flinching, first-turn-only moves, Toxic, multi-hit
/// moves, data-driven stat change targets, and which moves are battle-ready.
@Suite("Realistic rules")
struct RealisticRulesTests {
    static let chart = Fixtures.typeChart

    static func fighter(_ name: String = "Fighter", types: [String] = ["normal"], speed: Int = 80) -> Combatant {
        Combatant(pokemon: EngineTests.pokemon(name: name, types: types, hp: 100, speed: speed), moves: [])
    }

    static func engine(player: Combatant, opponent: Combatant) -> BattleEngine {
        BattleEngine(state: BattleState(player: player, opponent: opponent), typeChart: Self.chart)
    }

    static func move(_ name: String) -> MoveSnapshot {
        Fixtures.moves[name]!
    }

    static let splash = EngineTests.move(name: "splash", power: nil, damageClass: "status")

    // MARK: Stats

    @Test("Stats use the level-50 formulas with perfect IVs and no EVs")
    func levelFiftyStats() {
        // Garchomp: 108 / 130 / 95 / 80 / 85 / 102.
        let garchomp = Combatant(pokemon: Fixtures.roster.first { $0.pokemon.name == "garchomp" }!.pokemon, moves: [])
        #expect(garchomp.baseMaxHP == 183)
        #expect(garchomp.maxHP == Int(183 * BattleRules.standard.hpMultiplier))
        #expect(garchomp.attack == 150)
        #expect(garchomp.defense == 115)
        #expect(garchomp.specialAttack == 100)
        #expect(garchomp.specialDefense == 105)
        #expect(garchomp.speed == 122)
    }

    // MARK: Flinch and first-turn moves

    @Test("Fake Out makes a slower target flinch on the first turn only")
    func fakeOutFirstTurnOnly() {
        var engine = Self.engine(player: Self.fighter("Fast", speed: 120), opponent: Self.fighter("Slow", speed: 40))
        let firstRound = engine.resolveRound(playerMove: Self.move("fake-out"), opponentMove: Self.move("tackle"))
        #expect(firstRound.contains { if case .flinched(.opponent) = $0 { true } else { false } })
        #expect(!firstRound.contains { if case .used(.opponent, _) = $0 { true } else { false } })

        let secondRound = engine.resolveRound(playerMove: Self.move("fake-out"), opponentMove: Self.splash)
        #expect(secondRound.contains { if case .failed(.player) = $0 { true } else { false } })
    }

    @Test("A flinch does nothing to a target that already moved")
    func flinchNeedsTargetToMoveLater() {
        let alwaysFlinch = Self.move("iron-head")
        let flinching = MoveSnapshot(
            name: alwaysFlinch.name, displayName: alwaysFlinch.displayName, power: 80, accuracy: 100,
            priority: 0, damageClass: "physical", typeName: "steel", ailment: "none", ailmentChance: 0,
            drain: 0, healing: 0, effectChance: nil, statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false, flinchChance: 100
        )
        var engine = Self.engine(player: Self.fighter("Slow", speed: 40), opponent: Self.fighter("Fast", speed: 120))
        let events = engine.resolveRound(playerMove: flinching, opponentMove: Self.move("tackle"))
        #expect(!events.contains { if case .flinched = $0 { true } else { false } })
    }

    // MARK: Status

    @Test("Toxic damage escalates by 1/16 of the real level-50 HP each round")
    func toxicEscalates() {
        var victim = Self.fighter("Victim", speed: 40)
        victim.status = .poison
        victim.toxicCounter = 1
        var engine = Self.engine(player: Self.fighter("Player", speed: 120), opponent: victim)
        let maxHP = victim.baseMaxHP
        var ticks: [Int] = []
        for _ in 0..<3 {
            let events = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
            for case .statusTick(.opponent, .poison, let amount) in events { ticks.append(amount) }
        }
        #expect(ticks == [maxHP / 16, maxHP * 2 / 16, maxHP * 3 / 16])
    }

    @Test("Toxic badly poisons, regular poison doesn't escalate")
    func toxicSetsCounter() {
        var engine = Self.engine(player: Self.fighter("Player", speed: 120), opponent: Self.fighter("Target", speed: 40))
        let toxic = Self.move("toxic")
        // Toxic is 90% accurate; retry until it lands.
        for _ in 0..<20 where engine.state.opponent.status == .none {
            _ = engine.resolveRound(playerMove: toxic, opponentMove: Self.splash)
        }
        #expect(engine.state.opponent.isBadlyPoisoned)
    }

    @Test("Dream Eater fails unless the target is asleep")
    func dreamEaterNeedsSleep() {
        let dreamEater = EngineTests.move(name: "dream-eater", power: 100, damageClass: "special", typeName: "psychic", drain: 50)
        var engine = Self.engine(player: Self.fighter("Player", speed: 120), opponent: Self.fighter("Target", speed: 40))
        let events = engine.resolveRound(playerMove: dreamEater, opponentMove: Self.splash)
        #expect(events.contains { if case .failed(.player) = $0 { true } else { false } })
        #expect(engine.state.opponent.currentHP == engine.state.opponent.maxHP)
    }

    // MARK: Multi-hit

    @Test("Double Kick hits twice, reported as one damage event and a hit count")
    func fixedMultiHit() {
        var engine = Self.engine(player: Self.fighter("Player", speed: 120), opponent: Self.fighter("Target", speed: 40))
        let events = engine.resolveRound(playerMove: Self.move("double-kick"), opponentMove: Self.splash)
        let damage = events.compactMap { if case .damaged(.opponent, let amount, _, _) = $0 { amount } else { nil } }
        #expect(damage.count == 1)
        #expect(engine.state.opponent.maxHP - engine.state.opponent.currentHP == damage.first)
        #expect(events.contains { if case .hitCount(.opponent, 2) = $0 { true } else { false } })
    }

    @Test("Triple Axel's power rises with each hit")
    func escalatingMultiHit() {
        let tripleAxel = MoveSnapshot(
            name: "triple-axel", displayName: "Triple Axel", power: 20, accuracy: 100, priority: 0,
            damageClass: "physical", typeName: "ice", ailment: "none", ailmentChance: 0, drain: 0,
            healing: 0, effectChance: nil, statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false, minHits: 3, maxHits: 3
        )
        #expect(tripleAxel.expectedPowerMultiple == 6)
        #expect(Self.move("double-kick").expectedPowerMultiple == 2)
    }

    @Test("Tera Blast only lowers its user's stats for Stellar Terapagos")
    func teraBlastBySpecies() {
        let teraBlast = EngineTests.move(
            name: "tera-blast", power: 80, damageClass: "special",
            statChangeNames: ["attack", "special-attack"], statChangeDeltas: [-1, -1]
        )
        let pikachu = Combatant(pokemon: EngineTests.pokemon(name: "Pikachu"), moves: [])
        let terapagos = Combatant(pokemon: EngineTests.pokemon(name: "Terapagos-Stellar"), moves: [])
        #expect(teraBlast.resolved(for: pikachu).statChanges.isEmpty)
        #expect(teraBlast.resolved(for: terapagos).statChanges.map(\.target) == [.user, .user])
    }

    @Test(
        "Form-dependent moves take the user's form type",
        arguments: [
            ("ivy-cudgel", "ogerpon-wellspring-mask", "water"),
            ("ivy-cudgel", "ogerpon", "grass"),
            ("raging-bull", "tauros-paldea-blaze-breed", "fire"),
            ("raging-bull", "tauros", "normal"),
            ("aura-wheel", "morpeko-hangry", "dark"),
        ]
    )
    func formTypes(move: String, species: String, type: String) {
        let user = Combatant(pokemon: EngineTests.pokemon(name: species), moves: [])
        #expect(EngineTests.move(name: move).resolved(for: user).typeName == type)
    }

    @Test("Revelation Dance takes the user's type")
    func userTypeMoves() {
        let oricorio = Combatant(pokemon: EngineTests.pokemon(name: "oricorio-pom-pom", types: ["electric", "flying"]), moves: [])
        #expect(EngineTests.move(name: "revelation-dance").resolved(for: oricorio).typeName == "electric")
    }

    @Test("2-5 hit moves land 2 to 5 times")
    func variableMultiHit() {
        for _ in 0..<200 {
            #expect((2...5).contains(BattleEngineTestAccess.rollHits(min: 2, max: 5)))
        }
        #expect(BattleEngineTestAccess.rollHits(min: nil, max: nil) == 1)
    }

    // MARK: Stat change targets

    @Test("Close Combat lowers the user's defences, Crunch the target's")
    func statChangeTargetsFromData() {
        #expect(Self.move("close-combat").statChanges.allSatisfy { $0.target == .user })
        #expect(Self.move("crunch").statChanges.allSatisfy { $0.target == .opponent })
        #expect(Self.move("flame-charge").statChanges.allSatisfy { $0.target == .user })
        #expect(Self.move("screech").statChanges.allSatisfy { $0.target == .opponent })
        #expect(Self.move("shell-smash").statChanges.allSatisfy { $0.target == .user })

        var engine = Self.engine(player: Self.fighter("Player", speed: 120), opponent: Self.fighter("Target", speed: 40))
        _ = engine.resolveRound(playerMove: Self.move("close-combat"), opponentMove: Self.splash)
        #expect(engine.state.player.stage(for: "defense") == -1)
        #expect(engine.state.player.stage(for: "special-defense") == -1)
        #expect(engine.state.opponent.statStages.isEmpty)
    }

    // MARK: Battle readiness

    @Test(
        "Moves without a modeled effect aren't battle-ready",
        arguments: ["confuse-ray", "double-team", "sand-attack", "leech-seed", "yawn", "belly-drum", "solar-beam", "explosion"]
    )
    func unmodeledMovesExcluded(name: String) {
        #expect(!Self.move(name).isBattleReady)
    }

    @Test(
        "Modeled moves are battle-ready",
        arguments: ["swords-dance", "thunder-wave", "toxic", "recover", "rest", "growl", "fake-out", "dynamic-punch"]
    )
    func modeledMovesIncluded(name: String) {
        #expect(Self.move(name).isBattleReady)
    }
}

/// Test-only access to the engine's hit roll.
enum BattleEngineTestAccess {
    static func rollHits(min: Int?, max: Int?) -> Int {
        BattleEngine.rollHits(min: min, max: max)
    }
}

/// Pins down how ``BattleRules`` derives the HP multiplier.
@Suite("Battle rules configuration")
struct BattleRulesConfigurationTests {
    @Test("Real-game HP rules don't scale HP")
    func realGameHP() {
        #expect(BattleRules.realGameHP.hpMultiplier == 1)
    }

    @Test("More reference hits to KO means more HP", arguments: [6.0, 12.0, 20.0])
    func multiplierGrowsWithTarget(hits: Double) {
        let fewer = BattleRules(referenceHitsToKO: hits).hpMultiplier
        let more = BattleRules(referenceHitsToKO: hits + 4).hpMultiplier
        #expect(more > fewer)
    }

    @Test("The reference attack takes the target number of hits at any level", arguments: [30, 50, 100])
    func referenceHoldsAcrossLevels(level: Int) {
        let rules = BattleRules(level: level, referenceHitsToKO: 12)
        let reference = TestPokemon(
            id: 1, name: "Reference", frontSprite: "", backSprite: nil, typeNames: ["normal"],
            statLookup: ["hp": 80, "attack": 80, "defense": 80, "special-attack": 80, "special-defense": 80, "speed": 80]
        )
        let attacker = Combatant(pokemon: reference, moves: [], rules: rules)
        let defender = Combatant(pokemon: reference, moves: [], rules: rules)
        let move = EngineTests.move(power: 80)
        let hit = Double(DamageCalculator.estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: Fixtures.typeChart))
            * DamageCalculator.averageRoll
        #expect(abs(Double(defender.maxHP) / hit - 12) < 0.5)
    }
}


/// Decodes moves from real PokeAPI JSON, so the engine's reading of PokeAPI
/// values (like the "damage-raise" category spelling) can't drift from the
/// API.
@Suite("PokeAPI move decoding")
struct PokeAPIMoveDecodingTests {
    static func move(json: String) throws -> Move {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return Move(from: try decoder.decode(APIMoveResponse.self, from: Data(json.utf8)))
    }

    static func json(name: String, power: Int, category: String, stat: String, change: Int) -> String {
        """
        {"name": "\(name)", "power": \(power), "accuracy": 100, "pp": 5, "priority": 0,
         "damage_class": {"name": "special"}, "type": {"name": "grass"}, "effect_chance": null,
         "target": {"name": "selected-pokemon"},
         "meta": {"ailment": {"name": "none"}, "ailment_chance": 0, "drain": 0, "healing": 0,
                  "category": {"name": "\(category)"}, "min_hits": null, "max_hits": null,
                  "crit_rate": 0, "flinch_chance": 0},
         "stat_changes": [{"change": \(change), "stat": {"name": "\(stat)"}}]}
        """
    }

    @Test("A damage-raise move's drawback hits its user (Leaf Storm)")
    func damageRaiseTargetsUser() throws {
        let leafStorm = try Self.move(json: Self.json(name: "leaf-storm", power: 130, category: "damage-raise", stat: "special-attack", change: -2))
        #expect(leafStorm.statChangeTarget == .user)
    }

    @Test("A damage-lower move's drop hits its target (Energy Ball)")
    func damageLowerTargetsOpponent() throws {
        let energyBall = try Self.move(json: Self.json(name: "energy-ball", power: 90, category: "damage-lower", stat: "special-defense", change: -1))
        #expect(energyBall.statChangeTarget == .opponent)
    }
}
