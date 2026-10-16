import Testing
@testable import PokeBattleKit

/// Pins down round resolution in `BattleEngine`: turn order, damage, healing,
/// fainting, recharge, status ticks, and phase transitions.
@Suite("Battle engine")
struct EngineTests {
    static let chart = TypeChart(attackers: [
        "fire": TypeMatchup(doubleDamageTo: ["grass"], halfDamageTo: ["water", "fire"], noDamageTo: []),
        "water": TypeMatchup(doubleDamageTo: ["fire"], halfDamageTo: ["grass", "water"], noDamageTo: []),
        "normal": TypeMatchup(doubleDamageTo: [], halfDamageTo: [], noDamageTo: ["ghost"]),
        "electric": TypeMatchup(doubleDamageTo: ["water"], halfDamageTo: [], noDamageTo: []),
    ])

    static func pokemon(
        name: String = "Test",
        types: [String] = ["normal"],
        hp: Int = 100,
        attack: Int = 80,
        defense: Int = 80,
        spAttack: Int = 80,
        spDefense: Int = 80,
        speed: Int = 80
    ) -> TestPokemon {
        TestPokemon(
            id: 1, name: name, frontSprite: "", backSprite: nil,
            typeNames: types,
            statLookup: [
                "hp": hp, "attack": attack, "defense": defense,
                "special-attack": spAttack, "special-defense": spDefense, "speed": speed
            ]
        )
    }

    static func move(
        name: String = "tackle",
        power: Int? = 50,
        damageClass: String = "physical",
        typeName: String = "normal",
        accuracy: Int? = 100,
        priority: Int = 0,
        ailment: String = "none",
        ailmentChance: Int = 0,
        drain: Int = 0,
        healing: Int = 0,
        effectChance: Int? = nil,
        statChangeNames: [String] = [],
        statChangeDeltas: [Int] = [],
        isRechargeMove: Bool = false,
        hasSelfDebuff: Bool = false
    ) -> MoveSnapshot {
        MoveSnapshot(
            name: name, displayName: name.capitalized, power: power, accuracy: accuracy,
            priority: priority, damageClass: damageClass, typeName: typeName,
            ailment: ailment, ailmentChance: ailmentChance, drain: drain, healing: healing,
            effectChance: effectChance, statChangeNames: statChangeNames,
            statChangeDeltas: statChangeDeltas,
            isRechargeMove: isRechargeMove, hasSelfDebuff: hasSelfDebuff
        )
    }

    /// The side that acted, if `event` is a `.used` event.
    static func actingSide(of event: Event) -> Side? {
        if case .used(let side, _) = event { return side }
        return nil
    }

    @Test("A round emits a used event for each side")
    func roundEmitsUsedEvents() {
        let p = Combatant(pokemon: Self.pokemon(name: "Player", speed: 100), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Opponent", speed: 50), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let events = engine.resolveRound(playerMove: Self.move(), opponentMove: Self.move())
        let usedNames = events.compactMap { event -> String? in
            if case .used(_, let name) = event { return name }
            return nil
        }
        #expect(usedNames.count == 2)
    }

    @Test("Faster Pokemon moves first")
    func fasterGoesFirst() throws {
        let p = Combatant(pokemon: Self.pokemon(name: "Fast", speed: 200), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Slow", speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let events = engine.resolveRound(playerMove: Self.move(), opponentMove: Self.move())
        let first = try #require(events.first)
        #expect(Self.actingSide(of: first) == .player, "Faster Pokemon should go first")
    }

    @Test("Priority move goes first regardless of speed")
    func priorityOverridesSpeed() throws {
        let p = Combatant(pokemon: Self.pokemon(name: "Slow", speed: 10), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Fast", speed: 200), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let quickAttack = Self.move(name: "quick-attack", priority: 1)
        let events = engine.resolveRound(playerMove: quickAttack, opponentMove: Self.move())
        let first = try #require(events.first)
        #expect(Self.actingSide(of: first) == .player, "Priority move should go first regardless of speed")
    }

    @Test("Damaging move reduces the defender's HP")
    func damageReducesHP() {
        let p = Combatant(pokemon: Self.pokemon(name: "Attacker", speed: 200), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Defender", speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let startHP = engine.state.opponent.currentHP
        _ = engine.resolveRound(playerMove: Self.move(power: 80), opponentMove: Self.move(power: 0))
        #expect(engine.state.opponent.currentHP < startHP)
    }

    @Test("Fainting the opponent ends the match")
    func faintEndsMatch() {
        let p = Combatant(pokemon: Self.pokemon(name: "Attacker", attack: 999, speed: 200), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Victim", hp: 1, speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let events = engine.resolveRound(playerMove: Self.move(power: 200), opponentMove: Self.move())
        let ended = events.contains { if case .ended = $0 { return true }; return false }
        let fainted = events.contains { if case .fainted(.opponent) = $0 { return true }; return false }
        #expect(ended)
        #expect(fainted)
    }

    @Test("Healing move restores HP")
    func healingRestoresHP() {
        var p = Combatant(pokemon: Self.pokemon(name: "Healer", speed: 200), moves: [])
        p.currentHP = p.maxHP / 2
        let halfHP = p.currentHP
        let o = Combatant(pokemon: Self.pokemon(name: "Opponent", speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let healMove = Self.move(name: "synthesis", power: nil, damageClass: "status", healing: 50)
        _ = engine.resolveRound(playerMove: healMove, opponentMove: Self.move(power: 0))
        #expect(engine.state.player.currentHP > halfHP)
    }

    @Test("Recharge move skips the user's next turn")
    func rechargeMoveSkipsNextTurn() throws {
        let p = Combatant(pokemon: Self.pokemon(name: "Recharg", speed: 200), moves: [])
        let o = Combatant(pokemon: Self.pokemon(name: "Foe", speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let hyperBeam = Self.move(name: "hyper-beam", power: 150, isRechargeMove: true)
        _ = engine.resolveRound(playerMove: hyperBeam, opponentMove: Self.move(power: 0))
        try #require(engine.state.player.mustRecharge)
        let events2 = engine.resolveRound(playerMove: Self.move(), opponentMove: Self.move(power: 0))
        let recharging = events2.contains { if case .recharging(.player) = $0 { return true }; return false }
        #expect(recharging)
    }

    @Test("Burn deals damage at the end of the round")
    func statusTickDamage() {
        var p = Combatant(pokemon: Self.pokemon(name: "Burned", speed: 200), moves: [])
        p.status = .burn
        let o = Combatant(pokemon: Self.pokemon(name: "Foe", speed: 10), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        let startHP = engine.state.player.currentHP
        _ = engine.resolveRound(playerMove: Self.move(power: 0), opponentMove: Self.move(power: 0))
        #expect(engine.state.player.currentHP < startHP)
    }

    @Test("Phase resets to move selection after a non-fatal round")
    func phaseResetsAfterRound() {
        let p = Combatant(pokemon: Self.pokemon(speed: 100), moves: [])
        let o = Combatant(pokemon: Self.pokemon(speed: 50), moves: [])
        var engine = BattleEngine(state: BattleState(player: p, opponent: o), typeChart: Self.chart)
        _ = engine.resolveRound(playerMove: Self.move(power: 10), opponentMove: Self.move(power: 10))
        let isSelectingMove = if case .selectingMove = engine.state.phase { true } else { false }
        #expect(isSelectingMove, "Phase should reset to selectingMove after non-fatal round")
    }
}

extension EngineTests {
    /// Everything observable about one seeded simulated battle.
    struct Replay: Equatable {
        var winner: Side?
        var turns: Int
        var loadouts: [[String]]
        var picks: [String]
        var finalHP: [Int]
        var events: [String]
    }

    static func replay(_ player: Fixtures.Species, _ opponent: Fixtures.Species, seed: UInt64) -> Replay {
        var generator = SeededGenerator(state: seed)
        var picks: [String] = []
        // Easy on the opponent, so the loadout handicap's draw is covered too.
        let result = BattleSimulator.battle(
            player: .init(pokemon: player.pokemon, movepool: Fixtures.battleReadyMoves(for: player)),
            opponent: .init(pokemon: opponent.pokemon, movepool: Fixtures.battleReadyMoves(for: opponent), difficulty: .easy),
            typeChart: Fixtures.typeChart, using: &generator,
            onPick: { picks.append("\($0.side) \($0.move.name) \($0.attacker.currentHP)/\($0.defender.currentHP)") }
        )
        // The engine on its own, replaying the simulator's loadouts.
        var engine = BattleEngine(
            state: BattleState(
                player: Combatant(pokemon: player.pokemon, moves: result.playerLoadout),
                opponent: Combatant(pokemon: opponent.pokemon, moves: result.opponentLoadout)
            ),
            typeChart: Fixtures.typeChart
        )
        var events: [String] = []
        for _ in 0..<20 {
            events += engine.resolveRound(
                playerMove: result.playerLoadout[0], opponentMove: result.opponentLoadout[0], using: &generator
            ).map { String(describing: $0) }
        }
        return Replay(
            winner: result.winner, turns: result.turns,
            loadouts: [result.playerLoadout.map(\.name), result.opponentLoadout.map(\.name)],
            picks: picks,
            finalHP: [result.finalState.player.currentHP, result.finalState.opponent.currentHP],
            events: events
        )
    }

    @Test("A seeded simulation replays exactly")
    func seededSimulationIsReproducible() {
        let pairs = zip(Fixtures.roster, Fixtures.roster.dropFirst()).prefix(6)
        var differsWithAnotherSeed = false
        for (player, opponent) in pairs {
            let first = Self.replay(player, opponent, seed: 99)
            let second = Self.replay(player, opponent, seed: 99)
            #expect(first == second, "\(player.pokemon.name) vs \(opponent.pokemon.name)")
            #expect(!first.picks.isEmpty && !first.events.isEmpty)
            if Self.replay(player, opponent, seed: 100) != first { differsWithAnotherSeed = true }
        }
        // The seed actually drives the randomness.
        #expect(differsWithAnotherSeed)
    }
}
