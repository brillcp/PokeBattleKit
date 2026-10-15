import Testing
@testable import PokeBattleKit

/// Pins down battle rules that follow the main games: speed stat stages in
/// turn order, sleep length, and type-based immunity to status conditions.
@Suite("Battle rules")
struct BattleRulesTests {
    static let chart = TypeChart(attackers: [
        "normal": TypeMatchup(doubleDamageTo: [], halfDamageTo: [], noDamageTo: ["ghost"]),
        "electric": TypeMatchup(doubleDamageTo: ["water"], halfDamageTo: [], noDamageTo: ["ground"]),
        "psychic": TypeMatchup(doubleDamageTo: [], halfDamageTo: [], noDamageTo: ["dark"]),
        "fire": TypeMatchup(doubleDamageTo: ["grass"], halfDamageTo: ["fire"], noDamageTo: []),
        "grass": TypeMatchup(doubleDamageTo: [], halfDamageTo: ["fire"], noDamageTo: []),
        "poison": TypeMatchup(doubleDamageTo: ["grass"], halfDamageTo: [], noDamageTo: ["steel"]),
    ])

    /// A move that does nothing, so the other side's turn never interferes.
    static let splash = EngineTests.move(name: "splash", power: nil, damageClass: "status")

    static func statusMove(_ name: String, type: String, ailment: String) -> MoveSnapshot {
        EngineTests.move(name: name, power: nil, damageClass: "status", typeName: type, ailment: ailment)
    }

    static func engine(player: Combatant, opponent: Combatant) -> BattleEngine {
        BattleEngine(state: BattleState(player: player, opponent: opponent), typeChart: Self.chart)
    }

    static func combatant(_ name: String, types: [String] = ["normal"], speed: Int = 80) -> Combatant {
        Combatant(pokemon: EngineTests.pokemon(name: name, types: types, hp: 200, speed: speed), moves: [])
    }

    // MARK: Speed stages

    // Base 80 Speed is 100 at level 50.
    @Test("Speed stat stages scale effective speed", arguments: zip([0, 2, -1, 6], [100, 200, 66, 400]))
    func speedStageScalesEffectiveSpeed(stage: Int, expected: Int) {
        var fighter = Self.combatant("Fighter", speed: 80)
        fighter.applyStage("speed", delta: stage)
        #expect(fighter.effectiveSpeed == expected)
    }

    @Test("Paralysis halves the stage-adjusted speed")
    func paralysisHalvesStagedSpeed() {
        var fighter = Self.combatant("Fighter", speed: 80)
        fighter.applyStage("speed", delta: 2)
        fighter.status = .paralysis
        #expect(fighter.effectiveSpeed == 100)
    }

    @Test("A speed boost lets the slower Pokémon move first")
    func speedBoostChangesTurnOrder() throws {
        var player = Self.combatant("Player", speed: 50)
        player.applyStage("speed", delta: 2)
        var engine = Self.engine(player: player, opponent: Self.combatant("Opponent", speed: 80))
        let events = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
        let first = try #require(events.first)
        #expect(EngineTests.actingSide(of: first) == .player)
    }

    // MARK: Sleep

    @Test("A sleep counter of N skips exactly N turns", arguments: [1, 2, 3])
    func sleepCounterSkipsNTurns(turns: Int) {
        var player = Self.combatant("Player", speed: 100)
        player.status = .sleep
        player.sleepTurns = turns
        var engine = Self.engine(player: player, opponent: Self.combatant("Opponent", speed: 50))

        for _ in 0..<turns {
            let events = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
            #expect(events.contains { if case .fastAsleep(.player) = $0 { true } else { false } })
        }
        let wakeRound = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
        #expect(wakeRound.contains { if case .wokeUp(.player) = $0 { true } else { false } })
        #expect(engine.state.player.status == .none)
    }

    @Test("Rest heals the real level-50 HP and puts the user to sleep for two turns")
    func restSleepsTwoTurns() {
        var player = Self.combatant("Player", speed: 100)
        player.currentHP = 50
        var engine = Self.engine(player: player, opponent: Self.combatant("Opponent", speed: 50))
        let rest = EngineTests.move(name: "rest", power: nil, damageClass: "status", typeName: "psychic")

        _ = engine.resolveRound(playerMove: rest, opponentMove: Self.splash)
        #expect(engine.state.player.currentHP == 50 + player.baseMaxHP)
        #expect(engine.state.player.status == .sleep)

        for _ in 0..<2 {
            let events = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
            #expect(events.contains { if case .fastAsleep(.player) = $0 { true } else { false } })
        }
        let wakeRound = engine.resolveRound(playerMove: Self.splash, opponentMove: Self.splash)
        #expect(wakeRound.contains { if case .wokeUp(.player) = $0 { true } else { false } })
    }

    // MARK: Status immunities

    @Test("A damaging move with no effect can't inflict its ailment")
    func noEffectDamagingMoveInflictsNothing() {
        let bodySlam = EngineTests.move(
            name: "body-slam", power: 85, typeName: "normal", ailment: "paralysis", ailmentChance: 100
        )
        var engine = Self.engine(
            player: Self.combatant("Player", speed: 100),
            opponent: Self.combatant("Ghost", types: ["ghost"], speed: 50)
        )
        _ = engine.resolveRound(playerMove: bodySlam, opponentMove: Self.splash)
        #expect(engine.state.opponent.status == .none)
    }

    @Test("Thunder Wave fails against a Ground type")
    func thunderWaveFailsAgainstGround() {
        var engine = Self.engine(
            player: Self.combatant("Player", speed: 100),
            opponent: Self.combatant("Ground", types: ["ground"], speed: 50)
        )
        let thunderWave = Self.statusMove("thunder-wave", type: "electric", ailment: "paralysis")
        let events = engine.resolveRound(playerMove: thunderWave, opponentMove: Self.splash)
        #expect(engine.state.opponent.status == .none)
        #expect(events.contains { if case .damaged(.opponent, 0, 0, _) = $0 { true } else { false } })
    }

    @Test(
        "A type that can't have a status is never given it",
        arguments: [
            ("stun-spore", "grass", "paralysis", "electric"),
            ("will-o-wisp", "fire", "burn", "fire"),
            ("poison-powder", "poison", "poison", "poison"),
            ("toxic", "poison", "bad-poison", "steel"),
        ]
    )
    func statusImmuneTypes(move: String, moveType: String, ailment: String, targetType: String) {
        var engine = Self.engine(
            player: Self.combatant("Player", speed: 100),
            opponent: Self.combatant("Target", types: [targetType], speed: 50)
        )
        let statusMove = Self.statusMove(move, type: moveType, ailment: ailment)
        _ = engine.resolveRound(playerMove: statusMove, opponentMove: Self.splash)
        #expect(engine.state.opponent.status == .none)
    }

    @Test(
        "Status moves still work when the target isn't immune",
        arguments: [
            ("will-o-wisp", "fire", "burn", "grass", Status.burn),
            // Most status moves ignore type matchups: Hypnosis still hits a Dark type.
            ("hypnosis", "psychic", "sleep", "dark", Status.sleep),
        ]
    )
    func statusLandsOnNonImmuneTarget(move: String, moveType: String, ailment: String, targetType: String, expected: Status) {
        var engine = Self.engine(
            player: Self.combatant("Player", speed: 100),
            opponent: Self.combatant("Target", types: [targetType], speed: 50)
        )
        let statusMove = Self.statusMove(move, type: moveType, ailment: ailment)
        _ = engine.resolveRound(playerMove: statusMove, opponentMove: Self.splash)
        #expect(engine.state.opponent.status == expected)
    }

    // MARK: AI agrees with the engine

    @Test("AI never values Thunder Wave against a Ground type")
    func aiDisallowsThunderWaveIntoGround() {
        let score = MoveScoring.score(
            move: Self.statusMove("thunder-wave", type: "electric", ailment: "paralysis"),
            fighter: Self.combatant("AI"),
            opponent: Self.combatant("Ground", types: ["ground"]),
            typeChart: Self.chart
        )
        #expect(score == MoveScoring.Weights.disallowed)
    }

    @Test("AI gives no status value against a status-immune type")
    func aiIgnoresStatusIntoImmuneType() {
        let willOWisp = Self.statusMove("will-o-wisp", type: "fire", ailment: "burn")
        let intoFire = MoveScoring.score(
            move: willOWisp, fighter: Self.combatant("AI"),
            opponent: Self.combatant("Fire", types: ["fire"]), typeChart: Self.chart
        )
        let intoGrass = MoveScoring.score(
            move: willOWisp, fighter: Self.combatant("AI"),
            opponent: Self.combatant("Grass", types: ["grass"]), typeChart: Self.chart
        )
        #expect(intoFire == 0)
        #expect(intoGrass > 0)
    }
}
