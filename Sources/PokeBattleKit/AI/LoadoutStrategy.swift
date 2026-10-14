/// Heuristic AI for pre-battle loadout construction. Flow:
/// 1. `shortlist` curates a diverse 50-move pool for the host app's LLM.
/// 2. `heuristicPick` returns the 4-move fallback when the LLM is
///    unavailable or returns junk.
/// 3. `fill` pads partial LLM picks up to 4.
/// 4. `adjust` downgrades one damage move for fairness.
///
/// All candidates are ranked with
/// ``MoveScoring/score(move:fighter:opponent:typeChart:)`` against the
/// specific opponent, so loadouts are tailored to the matchup. Pass moves
/// already filtered with ``MoveData/isBattleReady``. Everything here is
/// deterministic except `adjust`, which picks its replacement at random.
public enum LoadoutStrategy {

    /// Up to `limit` moves, best-first, chosen to cover every role.
    ///
    /// Moves are taken from prioritized buckets: super-effective damaging
    /// moves first, then other damaging moves, boosts, disruption, and
    /// finally anything left. Each bucket is sorted by score, and moves
    /// already taken are skipped. Because all damaging moves come first,
    /// boost and disrupt moves appear only once every damaging move fits
    /// within `limit`; the generous default of 50 usually leaves room for
    /// them.
    public static func shortlist<M: MoveData>(
        fighter: Combatant,
        opponent: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        limit: Int = 50
    ) -> [M] {
        let ranked = rankedByScore(moves, fighter: fighter, opponent: opponent, typeChart: typeChart)
        let buckets: [[M]] = [
            ranked.filter { $0.isDamage && typeChart.multiplier(attacking: $0.typeName, defenders: opponent.typeNames) >= 2 },
            ranked.filter(\.isDamage),
            ranked.filter(\.isBoost),
            ranked.filter(\.isDisrupt),
            ranked
        ]
        return collapse(buckets, limit: limit)
    }

    /// A complete 4-move loadout without an LLM.
    ///
    /// Takes the best super-effective damaging move (if any), then fills
    /// with the highest-scoring damaging moves. Boost and disrupt moves only
    /// get in when there are fewer than four damaging moves, so in practice
    /// this is an attacking set. Pair with ``adjust(picks:pool:fighter:opponent:typeChart:)``
    /// for the AI side.
    public static func heuristicPick<M: MoveData>(
        fighter: Combatant,
        opponent: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        let ranked = rankedByScore(moves, fighter: fighter, opponent: opponent, typeChart: typeChart)
        let se = ranked.filter { $0.isDamage && typeChart.multiplier(attacking: $0.typeName, defenders: opponent.typeNames) >= 2 }
        let buckets: [[M]] = [
            Array(se.prefix(1)),
            ranked.filter(\.isDamage),
            ranked.filter(\.isBoost),
            ranked.filter(\.isDisrupt),
            ranked
        ]
        return collapse(buckets, limit: 4)
    }

    /// Pads `seed` (e.g. a partial or partly invalid LLM answer) to `count`
    /// moves with the best-scoring unused moves from `moves`. Keeps the
    /// seed's order and drops duplicate names; a seed that's already long
    /// enough is truncated to `count`.
    public static func fill<M: MoveData>(
        seed: [M],
        fighter: Combatant,
        opponent: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        count: Int
    ) -> [M] {
        guard seed.count < count else { return Array(seed.prefix(count)) }
        let ranked = rankedByScore(moves, fighter: fighter, opponent: opponent, typeChart: typeChart)
        return collapse([seed, ranked], limit: count)
    }

    /// Fairness handicap for an AI loadout: swaps its weakest damaging move
    /// for a deliberately weaker one from `pool`.
    ///
    /// A loadout tuned by ``MoveScoring`` against the player's exact
    /// Pokemon is close to optimal, which makes the AI feel unbeatable. One
    /// mediocre attack gives the player openings without making the AI
    /// obviously bad. The replacement:
    /// - is a damaging move not already in the loadout that can hit the
    ///   opponent,
    /// - deals less than 55% of the loadout's best estimated damage,
    /// - is drawn at random from the weaker half of such moves, so the AI
    ///   isn't handicapped the same way every time.
    ///
    /// Returns `picks` unchanged if it has fewer than two damaging moves
    /// (the AI keeps its main attack) or `pool` has no suitable
    /// replacement.
    public static func adjust<M: MoveData>(
        picks: [M],
        pool: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        handicap(picks, pool: pool, fighter: fighter, opponent: opponent, typeChart: typeChart)
    }
}

// MARK: - Private
private extension LoadoutStrategy {

    static func rankedByScore<M: MoveData>(
        _ moves: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        moves.sorted { lhs, rhs in
            MoveScoring.score(move: lhs, fighter: fighter, opponent: opponent, typeChart: typeChart)
            > MoveScoring.score(move: rhs, fighter: fighter, opponent: opponent, typeChart: typeChart)
        }
    }

    /// Walks each bucket in order, taking unseen moves until `limit`.
    /// Shared dedupe core for shortlist / heuristicPick / fill. Bucket order
    /// is the priority order; dedupe is by move name.
    static func collapse<M: MoveData>(_ buckets: [[M]], limit: Int) -> [M] {
        var seen: Set<String> = []
        var out: [M] = []
        for bucket in buckets {
            for move in bucket where seen.insert(move.name).inserted {
                out.append(move)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    static func handicap<M: MoveData>(
        _ loadout: [M],
        pool: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        let damageMoves = loadout.enumerated().filter { $0.element.isDamage }
        guard damageMoves.count >= 2 else { return loadout }

        func dmg(_ move: some MoveData) -> Int {
            DamageCalculator.estimateDamage(move: move, attacker: fighter, defender: opponent, typeChart: typeChart)
        }

        guard let weakest = damageMoves.min(by: { dmg($0.element) < dmg($1.element) }) else { return loadout }
        let bestDmg = max(1, damageMoves.map { dmg($0.element) }.max() ?? 1)
        let threshold = Int(Double(bestDmg) * 0.55)
        let used = Set(loadout.map(\.name))

        let candidates = pool
            .filter { $0.isDamage && !used.contains($0.name) }
            .filter { typeChart.multiplier(attacking: $0.typeName, defenders: opponent.typeNames) > 0 }
            .filter { dmg($0) > 0 && dmg($0) < threshold }
            .sorted { dmg($0) < dmg($1) }

        let bottomHalf = candidates.prefix(max(1, candidates.count / 2))
        guard let replacement = bottomHalf.randomElement() else { return loadout }

        var result = loadout
        result[weakest.offset] = replacement
        return result
    }
}
