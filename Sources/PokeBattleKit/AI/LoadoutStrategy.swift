/// Deterministic AI for pre-battle loadout construction. Flow:
/// 1. `shortlist` curates a diverse 50-move pool for the LLM.
/// 2. `heuristicPick` returns the 4-move fallback when the LLM is
///    unavailable or returns junk.
/// 3. `fill` pads partial LLM picks up to 4.
/// 4. `adjust` enforces 2 DMG + 1 BOOST + 1 DISRUPT composition and
///    downgrades one damage move for fairness.
public enum LoadoutStrategy {

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
    /// Shared dedupe core for shortlist / heuristicPick / fill.
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
