import Testing
@testable import PokeBattleKit

/// Pins down the heuristic AI: threat-aware and HP-aware scoring, the
/// correction pipeline, difficulty-dependent move choice, and role-based
/// loadouts.
@Suite("AI strategy")
struct AIStrategyTests {
    static let chart = Fixtures.typeChart

    static func species(_ name: String) -> Fixtures.Species {
        Fixtures.roster.first { $0.pokemon.name == name }!
    }

    static func combatant(_ name: String, moves: [String] = []) -> Combatant {
        Combatant(pokemon: species(name).pokemon, moves: moves.map { Fixtures.moves[$0]! })
    }

    static func move(_ name: String) -> MoveSnapshot { Fixtures.moves[name]! }

    /// Deterministic generator (SplitMix64) for reproducible picks.
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Scoring

    @Test("Healing is worth nothing at full HP and something when hurt")
    func healingNeedsMissingHP() {
        var fighter = Self.combatant("alakazam", moves: ["psychic", "recover"])
        let opponent = Self.combatant("snorlax", moves: ["body-slam"])
        let recover = Self.move("recover")
        #expect(MoveScoring.score(move: recover, fighter: fighter, opponent: opponent, typeChart: Self.chart) <= 0)
        fighter.currentHP = fighter.maxHP / 3
        #expect(MoveScoring.score(move: recover, fighter: fighter, opponent: opponent, typeChart: Self.chart) > 0)
    }

    @Test("A status move into an already-statused target is worth nothing")
    func noValueForSecondStatus() {
        let fighter = Self.combatant("jolteon", moves: ["thunderbolt", "thunder-wave"])
        var opponent = Self.combatant("snorlax", moves: ["body-slam"])
        opponent.status = .burn
        #expect(MoveScoring.score(move: Self.move("thunder-wave"), fighter: fighter, opponent: opponent, typeChart: Self.chart) == 0)
    }

    @Test("Close Combat's own Defense drops count against it")
    func selfDebuffIsPriced() {
        // Weezing resists Fighting, so Close Combat doesn't KO and the
        // drops matter for the rest of the fight.
        let fighter = Self.combatant("machamp", moves: ["close-combat", "cross-chop"])
        let opponent = Self.combatant("weezing", moves: ["sludge-bomb"])
        let closeCombat = Self.move("close-combat")
        let withoutDrops = MoveSnapshot(
            name: "close-combat-no-drops", displayName: "", power: 120, accuracy: 100, priority: 0,
            damageClass: "physical", typeName: "fighting", ailment: "none", ailmentChance: 0, drain: 0,
            healing: 0, effectChance: nil, statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false
        )
        let scoreWith = MoveScoring.score(move: closeCombat, fighter: fighter, opponent: opponent, typeChart: Self.chart)
        let scoreWithout = MoveScoring.score(move: withoutDrops, fighter: fighter, opponent: opponent, typeChart: Self.chart)
        #expect(scoreWith < scoreWithout)
    }

    @Test("A threatened, slower Pokémon prefers its priority move")
    func priorityUnderThreat() {
        var fighter = Self.combatant("scizor", moves: ["x-scissor", "bullet-punch"])
        let opponent = Self.combatant("arcanine", moves: ["flare-blitz"])
        fighter.currentHP = 20
        let pick = MoveStrategy.heuristicPick(
            attacker: fighter, defender: opponent, moves: fighter.moves,
            typeChart: Self.chart, recentMoves: [], difficulty: .hard
        )
        #expect(pick?.name == "bullet-punch")
    }

    @Test("A KO is worth more for an accurate move than an inaccurate one")
    func koBonusIsAccuracyWeighted() {
        let fighter = Self.combatant("machamp")
        var opponent = Self.combatant("snorlax")
        opponent.currentHP = 30
        let accurate = MoveScoring.score(move: Self.move("brick-break"), fighter: fighter, opponent: opponent, typeChart: Self.chart)
        let inaccurate = MoveScoring.score(move: Self.move("cross-chop"), fighter: fighter, opponent: opponent, typeChart: Self.chart)
        #expect(accurate > inaccurate)
    }

    // MARK: Correction pipeline

    @Test("Self-targeting moves aren't replaced for a type immunity")
    func selfTargetingIgnoresImmunity() {
        // A slow, weak Ghost type, so setting up is clearly worth it.
        let fighter = Self.combatant("lucario", moves: ["swords-dance", "close-combat", "meteor-mash"])
        let ghost = Combatant(
            pokemon: EngineTests.pokemon(name: "Ghost", types: ["ghost"], attack: 30, defense: 120, spAttack: 30, spDefense: 120, speed: 20),
            moves: [Self.move("tackle")]
        )
        let swordsDance = Self.move("swords-dance")
        #expect(MoveScoring.isUsable(swordsDance, attacker: fighter, defender: ghost, typeChart: Self.chart))
        let adjusted = MoveStrategy.adjust(
            pick: swordsDance, attacker: fighter, defender: ghost, moves: fighter.moves,
            typeChart: Self.chart, fallback: Self.move("close-combat")
        )
        #expect(adjusted.name == "swords-dance")
    }

    @Test("An unusable pick becomes the strongest attack, accounting for STAB")
    func unusableRepairUsesStrongestAttack() {
        // Close Combat can't touch Gengar; Fallback is unusable too, so the
        // strongest usable attack must win. Meteor Mash (STAB) beats Crunch
        // on raw power x type alone would not tell the whole story.
        let fighter = Self.combatant("lucario", moves: ["close-combat", "meteor-mash", "crunch"])
        let ghost = Self.combatant("gengar", moves: ["shadow-ball"])
        let adjusted = MoveStrategy.adjust(
            pick: Self.move("close-combat"), attacker: fighter, defender: ghost, moves: fighter.moves,
            typeChart: Self.chart, fallback: Self.move("close-combat")
        )
        let expected = MoveStrategy.strongestAttack(attacker: fighter, defender: ghost, moves: fighter.moves, typeChart: Self.chart)
        #expect(adjusted.name == expected?.name)
        #expect(adjusted.name != "close-combat")
    }

    @Test("Fake Out is replaced after the first turn")
    func fakeOutReplacedLater() {
        var fighter = Self.combatant("raichu", moves: ["fake-out", "thunderbolt"])
        fighter.turnsActive = 1
        let opponent = Self.combatant("gyarados", moves: ["waterfall"])
        let adjusted = MoveStrategy.adjust(
            pick: Self.move("fake-out"), attacker: fighter, defender: opponent, moves: fighter.moves,
            typeChart: Self.chart, fallback: Self.move("thunderbolt")
        )
        #expect(adjusted.name == "thunderbolt")
    }

    // MARK: Difficulty

    @Test("Hard always plays the best move")
    func hardIsDeterministic() {
        let fighter = Self.combatant("garchomp", moves: ["earthquake", "dragon-claw", "stone-edge", "swords-dance"])
        let opponent = Self.combatant("arcanine", moves: ["flare-blitz"])
        let picks = Set((0..<20).compactMap { _ in
            MoveStrategy.heuristicPick(attacker: fighter, defender: opponent, moves: fighter.moves, typeChart: Self.chart, recentMoves: [], difficulty: .hard)?.name
        })
        #expect(picks.count == 1)
    }

    @Test("Fair only varies between near-best moves")
    func fairStaysNearBest() {
        let fighter = Self.combatant("garchomp", moves: ["earthquake", "dragon-claw", "stone-edge", "swords-dance"])
        let opponent = Self.combatant("dragonite", moves: ["outrage"])
        let scores = Dictionary(uniqueKeysWithValues: fighter.moves.map {
            ($0.name, MoveScoring.inBattleScore(move: $0, attacker: fighter, defender: opponent, typeChart: Self.chart, recentMoves: []))
        })
        let best = scores.values.max()!
        var generator = SeededGenerator(state: 42)
        for _ in 0..<100 {
            let pick = MoveStrategy.heuristicPick(
                attacker: fighter, defender: opponent, moves: fighter.moves, typeChart: Self.chart,
                recentMoves: [], difficulty: .fair, using: &generator
            )!
            #expect(scores[pick.name]! >= best - max(best * 0.10, 3))
        }
    }

    // MARK: Loadouts

    @Test("Loadouts have two attack types and no duplicate attack types", arguments: Fixtures.roster.map(\.pokemon.name))
    func loadoutRoles(name: String) {
        let species = Self.species(name)
        let fighter = Combatant(pokemon: species.pokemon, moves: [])
        let opponent = Combatant(pokemon: Self.species(name == "snorlax" ? "lapras" : "snorlax").pokemon, moves: [])
        let loadout = LoadoutStrategy.heuristicPick(
            fighter: fighter, opponent: opponent, moves: Fixtures.battleReadyMoves(for: species), typeChart: Self.chart
        )
        let attackTypes = loadout.filter(\.isDamage).map(\.typeName)
        #expect(loadout.count == min(4, Fixtures.battleReadyMoves(for: species).count))
        #expect(Set(loadout.map(\.name)).count == loadout.count)
        #expect(Set(attackTypes).count >= min(2, Set(Fixtures.battleReadyMoves(for: species).filter(\.isDamage).map(\.typeName)).count))
        #expect(Set(attackTypes).count == attackTypes.count || attackTypes.count > 3)
    }

    @Test("Only easy handicaps the AI's loadout", arguments: Difficulty.allCases)
    func handicapOnlyOnEasy(difficulty: Difficulty) {
        let species = Self.species("garchomp")
        let fighter = Combatant(pokemon: species.pokemon, moves: [])
        let opponent = Combatant(pokemon: Self.species("lucario").pokemon, moves: [])
        let pool = Fixtures.battleReadyMoves(for: species)
        let picks = LoadoutStrategy.heuristicPick(fighter: fighter, opponent: opponent, moves: pool, typeChart: Self.chart)
        let adjusted = LoadoutStrategy.adjust(picks: picks, pool: pool, fighter: fighter, opponent: opponent, typeChart: Self.chart, difficulty: difficulty)
        if difficulty == .easy {
            #expect(adjusted.map(\.name) != picks.map(\.name))
        } else {
            #expect(adjusted.map(\.name) == picks.map(\.name))
        }
    }

    // MARK: Opponents

    @Test("Fair opponent pools have no one-sided type matchups")
    func fairPoolHasNoPushovers() {
        let player = Candidate(id: 45, name: "vileplume", typeNames: ["grass", "poison"], baseStatTotal: 490, isLegendary: false, isMythical: false)
        let pushover = Candidate(id: 763, name: "tsareena", typeNames: ["grass"], baseStatTotal: 510, isLegendary: false, isMythical: false)
        let even = Candidate(id: 131, name: "lapras", typeNames: ["water", "ice"], baseStatTotal: 535, isLegendary: false, isMythical: false)
        var generator = SeededGenerator(state: 1)
        let fair = OpponentStrategy.fairPool(for: player, from: [pushover, even], typeChart: Self.chart, using: &generator)
        #expect(!fair.contains { $0.name == "tsareena" })
    }

    @Test("Opponent picks vary and skip recent opponents")
    func opponentPicksVary() {
        let candidates = PokedexSimulationTests.roster.map(\.candidate)
        let player = candidates.first { $0.name == "charizard" }!
        var generator = SeededGenerator(state: 2)
        var picks: [Int] = []
        for _ in 0..<20 {
            let pick = OpponentStrategy.pick(for: player, from: candidates, typeChart: Self.chart, excluding: Set(picks.suffix(5)), using: &generator)!
            #expect(!picks.suffix(5).contains(pick.id))
            #expect(OpponentStrategy.fairWinChance.contains(OpponentStrategy.predictedWinChance(of: player, against: pick)))
            picks.append(pick.id)
        }
        #expect(Set(picks).count >= 15)
    }
}

extension AIStrategyTests {
    @Test("The loadout shortlist is ordered by score, not by bucket")
    func shortlistIsBestFirst() {
        let species = Self.species("garchomp")
        let fighter = Combatant(pokemon: species.pokemon, moves: [])
        let opponent = Combatant(pokemon: Self.species("lapras").pokemon, moves: [])
        let pool = Fixtures.battleReadyMoves(for: species)
        let shortlist = LoadoutStrategy.shortlist(fighter: fighter, opponent: opponent, moves: pool, typeChart: Self.chart, limit: pool.count)
        let scores = shortlist.map { MoveScoring.score(move: $0, fighter: fighter, opponent: opponent, typeChart: Self.chart) }
        #expect(scores == scores.sorted(by: >))
    }
}
