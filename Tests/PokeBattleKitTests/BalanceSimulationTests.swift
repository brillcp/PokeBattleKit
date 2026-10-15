import Testing
@testable import PokeBattleKit

/// Headless AI-vs-AI battles over every ordered pair of fixture Pokémon.
///
/// Both sides build their loadout and pick every move with the package's
/// heuristic AI, so the numbers measure the engine and the AI rather than a
/// human. The printed report is the tool for tuning balance; the
/// expectations only guard the properties the engine promises.
@Suite("Balance simulation", .serialized)
struct BalanceSimulationTests {

    /// Aggregate results over a batch of battles.
    struct Report: CustomStringConvertible {
        var battles = 0
        var playerWins = 0
        var draws = 0
        var turns: [Int] = []
        /// Battles between Pokémon at least 60 BST apart, and how many of
        /// those the weaker side won.
        var mismatched = 0
        var upsets = 0
        /// Battles between Pokémon less than 40 BST apart, and how many the
        /// player won.
        var even = 0
        var evenPlayerWins = 0
        var picksByCategory: [String: Int] = [:]
        var pairWins: [String: Int] = [:]

        var playerWinRate: Double { Double(playerWins) / Double(max(1, battles - draws)) }
        var averageTurns: Double { Double(turns.reduce(0, +)) / Double(max(1, turns.count)) }
        var oneShotRate: Double { Double(turns.filter { $0 <= 1 }.count) / Double(max(1, turns.count)) }
        var shortRate: Double { Double(turns.filter { $0 <= 2 }.count) / Double(max(1, turns.count)) }
        var longRate: Double { Double(turns.filter { $0 >= 12 }.count) / Double(max(1, turns.count)) }
        var upsetRate: Double { Double(upsets) / Double(max(1, mismatched)) }
        var evenWinRate: Double { Double(evenPlayerWins) / Double(max(1, even)) }
        var totalPicks: Int { picksByCategory.values.reduce(0, +) }

        func share(_ category: String) -> Double {
            Double(picksByCategory[category, default: 0]) / Double(max(1, totalPicks))
        }

        var description: String {
            func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
            let mix = ["DMG", "BOOST", "DISRUPT", "HEAL", "OTHER"]
                .map { "\($0) \(pct(share($0)))" }
                .joined(separator: ", ")
            let medianTurns = turns.sorted()[turns.count / 2]
            return """
            battles: \(battles) (draws \(draws))
            player win rate: \(pct(playerWinRate)) (even BST matchups: \(pct(evenWinRate)) of \(even))
            turns: avg \(String(format: "%.1f", averageTurns)), median \(medianTurns), \
            1-turn KO \(pct(oneShotRate)), <=2 turns \(pct(shortRate)), >=12 turns \(pct(longRate))
            upsets (weaker side wins, >=60 BST gap): \(pct(upsetRate)) of \(mismatched)
            move mix: \(mix)
            """
        }
    }

    /// How a side is set up, so the report can model the app's choices.
    struct Setup {
        var playerHPBonus = 1.0
        var difficulty: Difficulty = .fair
        /// Overrides the difficulty's level offset, for calibration.
        var opponentLevelOffset: Int? = nil
    }

    static let maxTurns = 50

    /// Runs `repeats` battles for every ordered pair of fixture species.
    static func simulate(_ setup: Setup, repeats: Int) -> Report {
        var report = Report()
        let roster = Fixtures.roster
        for player in roster {
            for opponent in roster where opponent.pokemon.id != player.pokemon.id {
                for _ in 0..<repeats {
                    let outcome = battle(player: player, opponent: opponent, setup: setup, report: &report)
                    record(outcome, player: player, opponent: opponent, into: &report)
                }
            }
        }
        return report
    }

    struct Outcome {
        let winner: Side?
        let turns: Int
    }

    static func battle(
        player: Fixtures.Species,
        opponent: Fixtures.Species,
        setup: Setup,
        report: inout Report
    ) -> Outcome {
        let chart = Fixtures.typeChart
        let playerPool = Fixtures.battleReadyMoves(for: player)
        let opponentPool = Fixtures.battleReadyMoves(for: opponent)

        // Loadouts are chosen against the other side's bare stats, as in the
        // app, where the moves aren't known yet.
        let rules = BattleRules.standard
        let opponentLevel = setup.opponentLevelOffset.map { rules.level + $0 }
            ?? rules.opponentLevel(for: setup.difficulty)
        let playerProbe = Combatant(pokemon: player.pokemon, moves: [], rules: rules)
        let opponentProbe = Combatant(pokemon: opponent.pokemon, moves: [], rules: rules, level: opponentLevel)
        let playerMoves = LoadoutStrategy.heuristicPick(
            fighter: playerProbe, opponent: opponentProbe, moves: playerPool, typeChart: chart
        )
        let opponentMoves = LoadoutStrategy.adjust(
            picks: LoadoutStrategy.heuristicPick(
                fighter: opponentProbe, opponent: playerProbe, moves: opponentPool, typeChart: chart
            ),
            pool: opponentPool, fighter: opponentProbe, opponent: playerProbe, typeChart: chart,
            difficulty: setup.difficulty
        )

        var engine = BattleEngine(
            state: BattleState(
                player: Combatant(pokemon: player.pokemon, moves: playerMoves, rules: rules, hpBonus: setup.playerHPBonus),
                opponent: Combatant(pokemon: opponent.pokemon, moves: opponentMoves, rules: rules, level: opponentLevel)
            ),
            typeChart: chart
        )

        var history: [Side: [String]] = [.player: [], .opponent: []]
        for turn in 1...maxTurns {
            // The player side stands in for a competent human: always fair.
            let playerMove = pick(for: .player, engine: engine, history: history[.player, default: []], difficulty: .fair)
            let opponentMove = pick(for: .opponent, engine: engine, history: history[.opponent, default: []], difficulty: setup.difficulty)
            for move in [playerMove, opponentMove] {
                report.picksByCategory[move.loadoutCategory, default: 0] += 1
            }
            history[.player, default: []].append(playerMove.name)
            history[.opponent, default: []].append(opponentMove.name)

            let events = engine.resolveRound(playerMove: playerMove, opponentMove: opponentMove)
            for event in events {
                if case .ended(let winner) = event { return Outcome(winner: winner, turns: turn) }
            }
        }
        return Outcome(winner: nil, turns: maxTurns)
    }

    /// The AI's move for `side`, the same way the app's fallback path picks
    /// one: the heuristic pick, then the correction pipeline.
    static func pick(for side: Side, engine: BattleEngine, history: [String], difficulty: Difficulty) -> MoveSnapshot {
        let chart = Fixtures.typeChart
        let attacker = side == .player ? engine.state.player : engine.state.opponent
        let defender = side == .player ? engine.state.opponent : engine.state.player
        let moves = attacker.moves
        let struggle = Fixtures.moves["tackle"]!
        guard let pick = MoveStrategy.heuristicPick(
            attacker: attacker, defender: defender, moves: moves, typeChart: chart,
            recentMoves: Array(history.suffix(4)), difficulty: difficulty
        ) else { return struggle }
        let fallback = DamageCalculator.strongestMove(
            attacker: attacker, defender: defender, moves: moves, typeChart: chart
        )?.move ?? pick
        return MoveStrategy.adjust(
            pick: pick, attacker: attacker, defender: defender, moves: moves,
            typeChart: chart, fallback: fallback
        )
    }

    static func record(_ outcome: Outcome, player: Fixtures.Species, opponent: Fixtures.Species, into report: inout Report) {
        report.battles += 1
        report.turns.append(outcome.turns)
        guard let winner = outcome.winner else {
            report.draws += 1
            return
        }
        if winner == .player { report.playerWins += 1 }
        let gap = player.bst - opponent.bst
        if abs(gap) >= 60 {
            report.mismatched += 1
            let weaker: Side = gap < 0 ? .player : .opponent
            if winner == weaker { report.upsets += 1 }
        }
        if abs(gap) < 40 {
            report.even += 1
            if winner == .player { report.evenPlayerWins += 1 }
        }
        let winnerName = winner == .player ? player.pokemon.name : opponent.pokemon.name
        report.pairWins[winnerName, default: 0] += 1
    }

    // MARK: - Tests

    @Test("Fair AI-vs-AI battles are balanced", arguments: [Difficulty.fair])
    func fairBattlesAreBalanced(difficulty: Difficulty) {
        let report = Self.simulate(Setup(difficulty: difficulty), repeats: 6)
        print("Balance report (\(difficulty)):\n\(report)")

        // Both sides use the same AI and nobody gets a handicap, so neither
        // side should have an edge.
        #expect((0.44...0.56).contains(report.playerWinRate))
        // Thanks to the extra bulk (`BattleRules.standard`), fights last
        // several turns and almost never end on the first hit, but still
        // finish well before the turn cap.
        #expect((5.0...10.0).contains(report.averageTurns))
        #expect(report.shortRate < 0.10)
        #expect(report.oneShotRate < 0.03)
        #expect(report.draws == 0)
        // A stronger Pokémon usually wins, but not always.
        #expect((0.10...0.35).contains(report.upsetRate))
        // The AI doesn't just spam attacks: support moves get used.
        #expect(report.share("DMG") < 0.97)
        #expect(report.share("DMG") > 0.70)
    }

    @Test("Easy favours the player and hard the AI")
    func difficultyOrdering() {
        let easy = Self.simulate(Setup(difficulty: .easy), repeats: 2)
        let hard = Self.simulate(Setup(difficulty: .hard), repeats: 2)
        #expect(easy.playerWinRate > 0.5)
        #expect(hard.playerWinRate < 0.5)
    }
}
