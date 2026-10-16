import Foundation
import Testing
@testable import PokeBattleKit

/// AI-vs-AI battles across the whole Pokédex, with matchups picked the way
/// the app picks them (`MatchmakingStrategy.pick`), checked for the properties
/// every battle should have. Also generates the strength ratings in
/// `PokemonStrength`.
///
/// The "player" side plays a strong, fair game (role-based loadout, fair
/// move choice) standing in for a good human; the opponent plays at the
/// difficulty under test, at its difficulty level. Besides aggregate
/// numbers, every turn is checked: no move that can't work is ever chosen,
/// and on hard the AI never passes up a sure KO.
///
/// Every simulation is seeded, so its numbers are the same on every run.
/// The battle simulations take a while, so they only run with
/// `SIMULATE=1`:
/// `SIMULATE=1 swift test -c release -Xswiftc -enable-testing --filter PokedexSimulationTests`
@Suite("Whole Pokédex simulation", .serialized)
struct PokedexSimulationTests {

    struct Entry {
        let pokemon: SnapshotPokemon
        let moves: [MoveSnapshot]
        let candidate: Candidate
    }

    /// Every Pokémon, with its battle-ready moves plus Struggle if none of
    /// them attacks (as the app does). Loadouts can be smaller than four.
    static let struggle = PokeAPISnapshot.moves["struggle"].map { MoveSnapshot(from: $0) }
    static let roster: [Entry] = PokeAPISnapshot.pokemon.compactMap { pokemon in
        let moves = LoadoutStrategy.withFallbackAttack(PokeAPISnapshot.battleReadyMoves(for: pokemon), struggle: struggle)
        guard !moves.isEmpty else { return nil }
        let candidate = Candidate(
            id: pokemon.id, name: pokemon.name, typeNames: pokemon.typeNames,
            baseStatTotal: pokemon.baseStatTotal, isLegendary: false, isMythical: false
        )
        return Entry(pokemon: pokemon, moves: moves, candidate: candidate)
    }
    static let byID = Dictionary(uniqueKeysWithValues: roster.map { ($0.pokemon.id, $0) })
    static let chart = Fixtures.typeChart

    struct Report: CustomStringConvertible {
        var battles = 0
        var playerWins = 0
        var draws = 0
        var turns: [Int] = []
        var unusablePicks: [String] = []
        var missedKOs: [String] = []
        var emptyLoadouts: [String] = []
        var stalls: [String] = []
        var picks: [String: Int] = [:]

        var playerWinRate: Double { Double(playerWins) / Double(max(1, battles - draws)) }
        var averageTurns: Double { Double(turns.reduce(0, +)) / Double(max(1, turns.count)) }
        func rate(_ predicate: (Int) -> Bool) -> Double {
            Double(turns.filter(predicate).count) / Double(max(1, turns.count))
        }

        var description: String {
            func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
            let sorted = turns.sorted()
            let top = picks.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }
            return """
            battles \(battles) (draws \(draws)), player wins \(pct(playerWinRate))
            turns avg \(String(format: "%.1f", averageTurns)), median \(sorted.isEmpty ? 0 : sorted[sorted.count / 2]), \
            <=2 \(pct(rate { $0 <= 2 })), >=20 \(pct(rate { $0 >= 20 }))
            unusable picks \(unusablePicks.count), missed KOs \(missedKOs.count), loadouts without an attack \(emptyLoadouts.count)
            most picked: \(top.joined(separator: ", "))
            """
        }
    }

    /// Runs `count` battles: a random player Pokémon against an opponent
    /// picked for it as "Smart pick" does.
    static func simulate(_ difficulty: Difficulty, count: Int, seed: UInt64, levelOffset: Int? = nil) -> Report {
        var generator = SeededGenerator(state: seed)
        var report = Report()
        let candidates = roster.map(\.candidate)
        let rules = BattleRules.standard
        let opponentLevel = levelOffset.map { rules.level + $0 } ?? rules.opponentLevel(for: difficulty)
        for _ in 0..<count {
            let player = roster.randomElement(using: &generator)!
            guard let pick = MatchmakingStrategy.pick(for: player.candidate, from: candidates, typeChart: chart, using: &generator),
                  let opponent = byID[pick.id] else { continue }
            var picksReport = report
            let result = BattleSimulator.battle(
                player: .init(pokemon: player.pokemon, movepool: player.moves, difficulty: .fair),
                opponent: .init(pokemon: opponent.pokemon, movepool: opponent.moves, difficulty: difficulty, level: opponentLevel),
                rules: rules, typeChart: chart, using: &generator,
                onPick: { check($0, difficulty: $0.side == .player ? .fair : difficulty, report: &picksReport) }
            )
            report = picksReport
            record(result, player: player, opponent: opponent, report: &report)
        }
        return report
    }

    static func record(_ result: BattleSimulator.Result, player: Entry, opponent: Entry, report: inout Report) {
        report.battles += 1
        report.turns.append(result.turns)
        let sides = [
            (result.finalState.player, result.playerLoadout, result.finalState.opponent),
            (result.finalState.opponent, result.opponentLoadout, result.finalState.player),
        ]
        for (attacker, loadout, foe) in sides where !loadout.contains(where: {
            $0.isDamage && MoveScoring.isUsable($0, attacker: attacker, defender: foe, typeChart: chart)
        }) {
            report.emptyLoadouts.append("\(attacker.name) vs \(foe.name): \(loadout.map(\.name))")
        }
        guard let winner = result.winner else {
            report.draws += 1
            report.stalls.append("\(player.pokemon.name) \(result.playerLoadout.map(\.name)) vs \(opponent.pokemon.name) \(result.opponentLoadout.map(\.name))")
            return
        }
        if winner == .player { report.playerWins += 1 }
    }

    /// The per-turn invariants.
    static func check(_ pick: BattleSimulator.Pick, difficulty: Difficulty, report: inout Report) {
        let (attacker, defender, move) = (pick.attacker, pick.defender, pick.move)
        report.picks[move.name, default: 0] += 1
        if !MoveScoring.isUsable(move, attacker: attacker, defender: defender, typeChart: chart),
           attacker.moves.contains(where: { MoveScoring.isUsable($0, attacker: attacker, defender: defender, typeChart: chart) }) {
            report.unusablePicks.append("\(attacker.name) used \(move.name) on \(defender.name)")
        }
        guard difficulty == .hard else { return }
        let sureKO = attacker.moves.contains { candidate in
            (candidate.accuracy ?? 100) >= 100
                && candidate.priority >= move.priority
                && MoveScoring.isUsable(candidate, attacker: attacker, defender: defender, typeChart: chart)
                && Double(DamageCalculator.estimateDamage(move: candidate, attacker: attacker, defender: defender, typeChart: chart)) * 0.85
                    >= Double(defender.currentHP)
        }
        let pickKOs = DamageCalculator.estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: chart) >= defender.currentHP
        if sureKO, !pickKOs {
            report.missedKOs.append("\(attacker.name) used \(move.name) on \(defender.name) at \(defender.currentHP) HP")
        }
    }

    // MARK: - Tests

    @Test("Every Pokémon can battle")
    func rosterCoverage() {
        let excluded = PokeAPISnapshot.pokemon.filter { Self.byID[$0.id] == nil }
        let borrowed = PokeAPISnapshot.pokemon.filter { $0.moves.isEmpty }.count
        print("Can battle: \(Self.roster.count) of \(PokeAPISnapshot.pokemon.count) (\(borrowed) forms with no PokeAPI learnset use their base species')")
        #expect(excluded.isEmpty, "Can't battle: \(excluded.map(\.name))")
    }

    @Test("Every Pokémon has a simulated strength rating")
    func everyoneIsRated() {
        let unrated = Self.roster.filter { !PokemonStrength.isRated($0.pokemon.name) }
        #expect(unrated.isEmpty, "Unrated (regenerate strength-ratings.json): \(unrated.prefix(20).map(\.pokemon.name))")
    }

    @Test("Strength ratings predict battle outcomes", .enabled(if: ProcessInfo.processInfo.environment["SIMULATE"] != nil), .timeLimit(.minutes(5)))
    func ratingsPredictOutcomes() {
        // Matchups the ratings call lopsided should mostly go the
        // predicted way; this guards against stale ratings after a rule
        // change.
        var generator = SeededGenerator(state: 5)
        var predicted = 0, correct = 0
        for _ in 0..<600 {
            let a = Self.roster.randomElement(using: &generator)!
            let b = Self.roster.randomElement(using: &generator)!
            let chance = MatchmakingStrategy.predictedWinChance(of: a.candidate, against: b.candidate)
            guard abs(chance - 0.5) > 0.25 else { continue }
            let result = BattleSimulator.battle(
                player: .init(pokemon: a.pokemon, movepool: a.moves), opponent: .init(pokemon: b.pokemon, movepool: b.moves),
                typeChart: Self.chart, using: &generator
            )
            guard let winner = result.winner else { continue }
            predicted += 1
            if (winner == .player) == (chance > 0.5) { correct += 1 }
        }
        print("Ratings called \(correct) of \(predicted) lopsided matchups correctly")
        #expect(Double(correct) / Double(max(1, predicted)) > 0.75)
    }

    @Test("Battles across the Pokédex are healthy", .enabled(if: ProcessInfo.processInfo.environment["SIMULATE"] != nil), .timeLimit(.minutes(10)), arguments: Difficulty.allCases)
    func healthyBattles(difficulty: Difficulty) {
        let report = Self.simulate(difficulty, count: 500, seed: 7)
        print("Pokédex simulation (\(difficulty), opponent \(difficulty.opponentLevelOffset) levels):\n\(report)")
        if !report.unusablePicks.isEmpty { print("  unusable: \(report.unusablePicks.prefix(10))") }
        if !report.missedKOs.isEmpty { print("  missed KOs: \(report.missedKOs.prefix(10))") }
        if !report.emptyLoadouts.isEmpty { print("  no attack: \(report.emptyLoadouts.prefix(10))") }
        for stall in report.stalls.prefix(8) { print("  stall: \(stall)") }

        // Every battle: no unusable move picked, a real attack in nearly
        // every loadout, and on hard no sure KO passed up.
        #expect(report.unusablePicks.isEmpty)
        #expect(Double(report.emptyLoadouts.count) / Double(report.battles) < 0.005)
        if difficulty == .hard { #expect(report.missedKOs.isEmpty) }
        // Battle length: several turns, rarely over on the first exchanges,
        // never stuck.
        #expect((5.0...10.0).contains(report.averageTurns))
        #expect(report.rate { $0 <= 2 } < 0.10)
        #expect(Double(report.draws) / Double(report.battles) < 0.005)
        // Difficulty hits its target win rate for a good player (within
        // sampling noise of one run).
        #expect(abs(report.playerWinRate - difficulty.targetPlayerWinRate) < 0.08)
    }

    // MARK: - Generators (opt-in)

    /// Finds each difficulty's opponent level offset that gives its target
    /// win rate. Run it after changing the AI, the rules or the ratings,
    /// then update `Difficulty.opponentLevelOffset`:
    /// `CALIBRATE=1 swift test -c release -Xswiftc -enable-testing --filter calibrateDifficulty`
    @Test("Calibrate difficulty level offsets", .enabled(if: ProcessInfo.processInfo.environment["CALIBRATE"] != nil))
    func calibrateDifficulty() {
        for difficulty in [Difficulty.easy, .hard] {
            let offsets = difficulty == .easy ? Array(stride(from: -3, through: -12, by: -1)) : Array(stride(from: 4, through: 12, by: 1))
            var results: [(Int, Double)] = []
            for offset in offsets {
                // Averaged over three samples of matchups to beat the noise.
                let rate = [3, 7, 11].map { Self.simulate(difficulty, count: 400, seed: $0, levelOffset: offset).playerWinRate }
                    .reduce(0, +) / 3
                results.append((offset, rate))
                print("CALIBRATE \(difficulty) offset \(offset): player wins \(Int((rate * 100).rounded()))%")
            }
            let best = results.min { abs($0.1 - difficulty.targetPlayerWinRate) < abs($1.1 - difficulty.targetPlayerWinRate) }!
            print("CALIBRATE \(difficulty): best offset \(best.0) (\(Int((best.1 * 100).rounded()))% vs target \(Int(difficulty.targetPlayerWinRate * 100))%)")
        }
    }

    /// Regenerates `Sources/PokeBattleKit/Resources/strength-ratings.json`.
    /// Every Pokémon fights `GAMES` (default 80) random opponents at equal
    /// level, both sides playing fair; the results are fitted to
    /// Bradley-Terry strengths (an MM fit), shown on the Elo scale (mean
    /// 1500). Run in release:
    /// `GENERATE_RATINGS=1 swift test -c release -Xswiftc -enable-testing --filter generateStrengthRatings`
    @Test("Generate strength ratings", .enabled(if: ProcessInfo.processInfo.environment["GENERATE_RATINGS"] != nil))
    func generateStrengthRatings() throws {
        let gamesPerPokemon = Int(ProcessInfo.processInfo.environment["GAMES"] ?? "") ?? 80
        let n = Self.roster.count
        var generator = SeededGenerator(state: 2026)
        var wins = [Double](repeating: 0, count: n)
        var pairs: [Int: [Int: Double]] = [:]
        for i in 0..<n {
            for game in 0..<gamesPerPokemon {
                var j = Int.random(in: 0..<n, using: &generator)
                if j == i { j = (j + 1) % n }
                let (a, b) = game.isMultiple(of: 2) ? (i, j) : (j, i)
                let result = BattleSimulator.battle(
                    player: .init(pokemon: Self.roster[a].pokemon, movepool: Self.roster[a].moves),
                    opponent: .init(pokemon: Self.roster[b].pokemon, movepool: Self.roster[b].moves),
                    typeChart: Self.chart, using: &generator
                )
                pairs[a, default: [:]][b, default: 0] += 1
                pairs[b, default: [:]][a, default: 0] += 1
                switch result.winner {
                case .player?: wins[a] += 1
                case .opponent?: wins[b] += 1
                case nil: wins[a] += 0.5; wins[b] += 0.5
                }
            }
            if i % 100 == 0 { print("RATINGS \(i)/\(n)") }
        }
        // Bradley-Terry by minorization-maximization, with one virtual win
        // and loss against an average (gamma 1) opponent for stability.
        var gamma = [Double](repeating: 1, count: n)
        for _ in 0..<200 {
            var next = gamma
            for i in 0..<n {
                var denominator = 2 / (gamma[i] + 1)
                for (j, count) in pairs[i] ?? [:] { denominator += count / (gamma[i] + gamma[j]) }
                next[i] = (wins[i] + 1) / denominator
            }
            let meanLog = next.map { log10($0) }.reduce(0, +) / Double(n)
            gamma = next.map { $0 / pow(10, meanLog) }
        }
        let ratings = gamma.map { 1500 + 400 * log10($0) }
        // Least-squares fit rating ~ BST, for unrated Pokémon.
        let bst = Self.roster.map { Double($0.pokemon.baseStatTotal) }
        let meanX = bst.reduce(0, +) / Double(n), meanY = ratings.reduce(0, +) / Double(n)
        let slope = zip(bst, ratings).map { ($0 - meanX) * ($1 - meanY) }.reduce(0, +)
            / bst.map { ($0 - meanX) * ($0 - meanX) }.reduce(0, +)
        let table = PokemonStrength.Table(
            method: "Bradley-Terry fit of \(gamesPerPokemon) simulated fair battles per Pokémon at level \(BattleRules.standard.level), vs random opponents",
            fit: .init(intercept: (meanY - slope * meanX).rounded(), slope: (slope * 1000).rounded() / 1000),
            ratings: Dictionary(uniqueKeysWithValues: zip(Self.roster.map(\.pokemon.name), ratings.map { $0.rounded() }))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeBattleKit/Resources/strength-ratings.json")
        try encoder.encode(table).write(to: url)
        let ranked = zip(Self.roster.map(\.pokemon.name), ratings).sorted { $0.1 > $1.1 }
        print("RATINGS wrote \(url.path)")
        print("RATINGS top: \(ranked.prefix(10).map { "\($0.0) \(Int($0.1))" })")
        print("RATINGS bottom: \(ranked.suffix(10).map { "\($0.0) \(Int($0.1))" })")
        print("RATINGS fit: rating ~ \(table.fit.intercept) + \(table.fit.slope) x BST")
    }
}
