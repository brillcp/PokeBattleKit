/// Heuristic AI for pre-battle loadout construction. Flow:
/// 1. `shortlist` ranks a movepool best first, for a host app that wants
///    to offer the choice to something else (a player, or a model).
/// 2. `heuristicPick` returns a complete loadout; use it directly, or as the
///    fallback when an external picker is unavailable or returns junk.
/// 3. `fill` pads a partial external pick up to 4.
/// 4. `adjust` applies the difficulty handicap (only on easy).
///
/// All candidates are ranked with
/// ``MoveScoring/score(move:fighter:opponent:typeChart:)`` against the
/// specific opponent, so loadouts are tailored to the matchup. Pass moves
/// already filtered with ``MoveData/isBattleReady``. Everything here is
/// deterministic except `adjust`, which picks its replacement at random
/// (from the generator passed to
/// ``adjust(picks:pool:fighter:opponent:typeChart:difficulty:using:)``).
public enum LoadoutStrategy {

    /// Up to `limit` moves, chosen to cover every role and returned
    /// best-first by score.
    ///
    /// When `limit` is smaller than the pool, moves are picked from
    /// prioritized buckets: super-effective damaging moves first, then
    /// other damaging moves, boosts, disruption, and finally anything left,
    /// so a short list still covers the roles. The picked moves are then
    /// ordered by score, so "first" always means "best" (a weak
    /// super-effective move doesn't sit above a strong neutral one).
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
        let picked = Set(collapse(buckets, limit: limit).map(\.name))
        return ranked.filter { picked.contains($0.name) }
    }

    /// A complete loadout of up to four moves, built by role:
    /// 1. the best attack,
    /// 2. the best attack of a different type,
    /// 3. the best support move (boost, status, or heal) if any is worth
    ///    using against this opponent, otherwise another attack of a new
    ///    type,
    /// 4. the best remaining move: an attack of a new type or a support
    ///    move of a different kind than slot 3.
    ///
    /// No two attacks share a type, so the set has coverage instead of
    /// three ways to do the same thing. Slots that can't be filled by role
    /// are topped up from the best-scoring leftovers. For the AI side, pass
    /// the result through ``adjust(picks:pool:fighter:opponent:typeChart:difficulty:)``.
    public static func heuristicPick<M: MoveData>(
        fighter: Combatant,
        opponent: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        complete(seed: [], fighter: fighter, opponent: opponent, moves: moves, typeChart: typeChart, count: 4)
    }

    /// Pads `seed` (e.g. a partial or partly invalid external pick) to `count`
    /// moves using the same roles as
    /// ``heuristicPick(fighter:opponent:moves:typeChart:)``, so the result
    /// still has a second attack type and room for a support move. Keeps the
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
        return complete(seed: seed, fighter: fighter, opponent: opponent, moves: moves, typeChart: typeChart, count: count)
    }

    /// `moves` with `struggle` added when none of them can deal damage, so
    /// every Pokémon can fight. In the games a Pokémon with nothing usable
    /// left uses Struggle; Pokémon like Wobbuffet or Ditto, whose
    /// battle-ready moves are all non-damaging here, get it the same way.
    /// Pass PokeAPI's "struggle" move.
    public static func withFallbackAttack<M: MoveData>(_ moves: [M], struggle: M?) -> [M] {
        guard !moves.contains(where: \.isDamage), let struggle else { return moves }
        return moves + [struggle]
    }

    /// Difficulty handicap for an AI loadout.
    ///
    /// On ``Difficulty/fair`` and ``Difficulty/hard`` the loadout is
    /// returned unchanged. On ``Difficulty/easy`` its strongest damaging
    /// move is swapped for a deliberately weaker one from `pool`, which
    /// gives the player openings without making the AI obviously bad (it
    /// keeps its other attacks). Swapping the strongest rather than the
    /// weakest matters: the AI rarely uses its weakest attack, so losing it
    /// changes nothing. The replacement:
    /// - is a damaging move not already in the loadout that can hit the
    ///   opponent,
    /// - deals less than 55% of the loadout's best estimated damage,
    /// - is drawn at random from the weaker half of such moves, so the AI
    ///   isn't handicapped the same way every time.
    ///
    /// Returns `picks` unchanged if it has fewer than two damaging moves
    /// (the AI keeps its main attack) or `pool` has no suitable
    /// replacement.
    ///
    /// Uses the system random number generator; see
    /// ``adjust(picks:pool:fighter:opponent:typeChart:difficulty:using:)``
    /// for reproducible handicaps.
    public static func adjust<M: MoveData>(
        picks: [M],
        pool: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding,
        difficulty: Difficulty = .fair
    ) -> [M] {
        var generator = SystemRandomNumberGenerator()
        return adjust(
            picks: picks, pool: pool, fighter: fighter, opponent: opponent,
            typeChart: typeChart, difficulty: difficulty, using: &generator
        )
    }

    /// ``adjust(picks:pool:fighter:opponent:typeChart:difficulty:)`` with an
    /// explicit random number generator for the replacement draw, for
    /// reproducible tests and simulations.
    public static func adjust<M: MoveData>(
        picks: [M],
        pool: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding,
        difficulty: Difficulty,
        using generator: inout some RandomNumberGenerator
    ) -> [M] {
        guard difficulty == .easy else { return picks }
        return handicap(picks, pool: pool, fighter: fighter, opponent: opponent, typeChart: typeChart, using: &generator)
    }
}

// MARK: - Private
private extension LoadoutStrategy {

    /// Moves best-first by score; each move is scored once. Ties keep
    /// their original order.
    static func rankedByScore<M: MoveData>(
        _ moves: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> [M] {
        scored(moves, fighter: fighter, opponent: opponent, typeChart: typeChart).map(\.move)
    }

    static func scored<M: MoveData>(
        _ moves: [M],
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> [(move: M, score: Double)] {
        moves.enumerated()
            .map { (index: $0.offset, move: $0.element, score: MoveScoring.score(move: $0.element, fighter: fighter, opponent: opponent, typeChart: typeChart)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map { ($0.move, $0.score) }
    }

    /// Role-based completion behind `heuristicPick` and `fill`. Walks the
    /// roles in order, skipping any the seed already covers: two attacks
    /// of different types, then the best support move, then whichever is
    /// better of a new-type attack and a different kind of support move.
    /// Support moves only count if they score above
    /// ``minimumSupportScore``.
    static func complete<M: MoveData>(
        seed: [M],
        fighter: Combatant,
        opponent: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        count: Int
    ) -> [M] {
        let ranked = scored(moves, fighter: fighter, opponent: opponent, typeChart: typeChart)
        var picks: [M] = []
        for move in seed where !picks.contains(where: { $0.name == move.name }) { picks.append(move) }

        func taken(_ move: M) -> Bool { picks.contains { $0.name == move.name } }
        func newAttackType(_ move: M) -> Bool {
            move.isDamage && !picks.contains { $0.isDamage && $0.typeName == move.typeName }
        }
        func supportKind(_ move: some MoveData) -> String { move.loadoutCategory }
        let attacks = ranked.filter { $0.move.isDamage && $0.score > MoveScoring.Weights.disallowed }
        let supports = ranked.filter { !$0.move.isDamage && $0.score > minimumSupportScore }

        // Slots 1-2: attacks with different types.
        while picks.count < count, picks.filter(\.isDamage).count < 2,
              let next = attacks.first(where: { !taken($0.move) && newAttackType($0.move) }) {
            picks.append(next.move)
        }
        // Slot 3: the best support move, if one is worth it.
        if picks.count < count, !picks.contains(where: { !$0.isDamage }),
           let support = supports.first(where: { !taken($0.move) }) {
            picks.append(support.move)
        }
        // Remaining slots: the better of a new-type attack and a support
        // move of a kind the loadout doesn't have yet.
        while picks.count < count {
            let kinds = Set(picks.filter { !$0.isDamage }.map(supportKind))
            let attack = attacks.first { !taken($0.move) && newAttackType($0.move) }
            let support = supports.first { !taken($0.move) && !kinds.contains(supportKind($0.move)) }
            guard let next = [attack, support].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { break }
            picks.append(next.move)
        }
        // Anything still missing comes from the best leftovers.
        return collapse([picks, ranked.map(\.move)], limit: count)
    }

    /// Support moves scoring at or below this (in HP-of-damage points)
    /// aren't worth a loadout slot.
    static var minimumSupportScore: Double { 8 }

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
        typeChart: some TypeEffectivenessProviding,
        using generator: inout some RandomNumberGenerator
    ) -> [M] {
        let damageMoves = loadout.enumerated().filter { $0.element.isDamage }
        guard damageMoves.count >= 2 else { return loadout }

        func dmg(_ move: some MoveData) -> Int {
            DamageCalculator.estimateDamage(move: move, attacker: fighter, defender: opponent, typeChart: typeChart)
        }

        guard let strongest = damageMoves.max(by: { dmg($0.element) < dmg($1.element) }) else { return loadout }
        let bestDmg = max(1, damageMoves.map { dmg($0.element) }.max() ?? 1)
        let threshold = Int(Double(bestDmg) * 0.55)
        let used = Set(loadout.map(\.name))

        let candidates = pool
            .filter { $0.isDamage && !used.contains($0.name) }
            .filter { typeChart.multiplier(attacking: $0.typeName, defenders: opponent.typeNames) > 0 }
            .filter { dmg($0) > 0 && dmg($0) < threshold }
            .sorted { dmg($0) < dmg($1) }

        let bottomHalf = candidates.prefix(max(1, candidates.count / 2))
        guard let replacement = bottomHalf.randomElement(using: &generator) else { return loadout }

        var result = loadout
        result[strongest.offset] = replacement
        return result
    }
}
