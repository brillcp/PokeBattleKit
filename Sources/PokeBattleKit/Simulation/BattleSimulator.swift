/// Runs complete AI-vs-AI battles with the package's own AI, headlessly.
///
/// Used to measure the engine and the AI across many matchups: the package
/// tests check every battle's health with it, and the strength ratings in
/// ``PokemonStrength`` come from it. Each side builds a role-based loadout
/// (``LoadoutStrategy``) and picks every move the way an app's AI would
/// (``MoveStrategy/heuristicPick(attacker:defender:moves:typeChart:recentMoves:difficulty:using:)``
/// followed by ``MoveStrategy/adjust(pick:attacker:defender:moves:typeChart:fallback:)``).
public enum BattleSimulator {

    /// One side of a simulated battle.
    public struct Fighter<P: PokemonData> {
        public let pokemon: P
        /// Battle-ready moves to build the loadout from.
        public let movepool: [MoveSnapshot]
        /// How this side's AI plays.
        public var difficulty: Difficulty
        /// Level override; `nil` uses the rules' level.
        public var level: Int?

        public init(pokemon: P, movepool: [MoveSnapshot], difficulty: Difficulty = .fair, level: Int? = nil) {
            self.pokemon = pokemon
            self.movepool = movepool
            self.difficulty = difficulty
            self.level = level
        }
    }

    /// A move choice, reported to the `onPick` observer.
    public struct Pick {
        public let side: Side
        public let attacker: Combatant
        public let defender: Combatant
        public let move: MoveSnapshot
    }

    public struct Result {
        /// `nil` if the battle hit the turn limit.
        public let winner: Side?
        public let turns: Int
        public let playerLoadout: [MoveSnapshot]
        public let opponentLoadout: [MoveSnapshot]
        public let finalState: BattleState
    }

    /// Plays one battle. The opponent's loadout gets its difficulty's
    /// handicap (``LoadoutStrategy/adjust(picks:pool:fighter:opponent:typeChart:difficulty:)``);
    /// `onPick` sees every move choice, for checking invariants.
    public static func battle<P: PokemonData, O: PokemonData>(
        player: Fighter<P>,
        opponent: Fighter<O>,
        rules: BattleRules = .standard,
        typeChart: TypeChart,
        maxTurns: Int = 60,
        using generator: inout some RandomNumberGenerator,
        onPick: (Pick) -> Void = { _ in }
    ) -> Result {
        let playerProbe = Combatant(pokemon: player.pokemon, moves: [], rules: rules, level: player.level)
        let opponentProbe = Combatant(pokemon: opponent.pokemon, moves: [], rules: rules, level: opponent.level)
        let playerMoves = LoadoutStrategy.adjust(
            picks: LoadoutStrategy.heuristicPick(fighter: playerProbe, opponent: opponentProbe, moves: player.movepool, typeChart: typeChart),
            pool: player.movepool, fighter: playerProbe, opponent: opponentProbe, typeChart: typeChart,
            difficulty: player.difficulty
        )
        let opponentMoves = LoadoutStrategy.adjust(
            picks: LoadoutStrategy.heuristicPick(fighter: opponentProbe, opponent: playerProbe, moves: opponent.movepool, typeChart: typeChart),
            pool: opponent.movepool, fighter: opponentProbe, opponent: playerProbe, typeChart: typeChart,
            difficulty: opponent.difficulty
        )
        var engine = BattleEngine(
            state: BattleState(
                player: Combatant(pokemon: player.pokemon, moves: playerMoves, rules: rules, level: player.level),
                opponent: Combatant(pokemon: opponent.pokemon, moves: opponentMoves, rules: rules, level: opponent.level)
            ),
            typeChart: typeChart
        )
        var history: [Side: [String]] = [:]
        for turn in 1...maxTurns {
            let playerMove = pick(.player, engine: engine, history: history[.player] ?? [], difficulty: player.difficulty, typeChart: typeChart, using: &generator, onPick: onPick)
            let opponentMove = pick(.opponent, engine: engine, history: history[.opponent] ?? [], difficulty: opponent.difficulty, typeChart: typeChart, using: &generator, onPick: onPick)
            history[.player, default: []].append(playerMove.name)
            history[.opponent, default: []].append(opponentMove.name)
            for event in engine.resolveRound(playerMove: playerMove, opponentMove: opponentMove) {
                if case .ended(let winner) = event {
                    return Result(winner: winner, turns: turn, playerLoadout: playerMoves, opponentLoadout: opponentMoves, finalState: engine.state)
                }
            }
        }
        return Result(winner: nil, turns: maxTurns, playerLoadout: playerMoves, opponentLoadout: opponentMoves, finalState: engine.state)
    }

    private static func pick(
        _ side: Side,
        engine: BattleEngine,
        history: [String],
        difficulty: Difficulty,
        typeChart: some TypeEffectivenessProviding,
        using generator: inout some RandomNumberGenerator,
        onPick: (Pick) -> Void
    ) -> MoveSnapshot {
        let attacker = side == .player ? engine.state.player : engine.state.opponent
        let defender = side == .player ? engine.state.opponent : engine.state.player
        let moves = attacker.moves
        let heuristic = MoveStrategy.heuristicPick(
            attacker: attacker, defender: defender, moves: moves, typeChart: typeChart,
            recentMoves: Array(history.suffix(4)), difficulty: difficulty, using: &generator
        ) ?? moves[0]
        let fallback = MoveStrategy.strongestAttack(attacker: attacker, defender: defender, moves: moves, typeChart: typeChart) ?? heuristic
        let move = MoveStrategy.adjust(
            pick: heuristic, attacker: attacker, defender: defender, moves: moves,
            typeChart: typeChart, fallback: fallback
        )
        onPick(Pick(side: side, attacker: attacker, defender: defender, move: move))
        return move
    }
}
