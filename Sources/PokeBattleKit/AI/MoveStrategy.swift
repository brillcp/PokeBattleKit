/// Deterministic AI for in-battle move selection. Owns the heuristic
/// fallback used when the host app's LLM picker is unavailable and the
/// post-pick correction pipeline applied to every chosen move regardless of
/// source.
///
/// The intended flow each turn:
///
/// ```swift
/// guard let pick = llmPick ?? MoveStrategy.heuristicPick(
///     attacker: ai, defender: player, moves: ai.moves,
///     typeChart: chart, recentMoves: aiHistory) else { return }
/// let final = MoveStrategy.adjust(
///     pick: pick, attacker: ai, defender: player,
///     moves: ai.moves, typeChart: chart, fallback: safeMove)
/// ```
///
/// Given the same inputs, both functions always return the same move.
public enum MoveStrategy {

    /// Highest-scoring move by
    /// ``MoveScoring/inBattleScore(move:attacker:defender:typeChart:recentMoves:)``,
    /// accounting for damage, recency, and low-HP bias. Ties go to the
    /// earliest move in `moves`. Returns `nil` only if `moves` is empty.
    public static func heuristicPick<M: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String]
    ) -> M? {
        moves.max { lhs, rhs in
            MoveScoring.inBattleScore(move: lhs, attacker: attacker, defender: defender, typeChart: typeChart, recentMoves: recentMoves)
            < MoveScoring.inBattleScore(move: rhs, attacker: attacker, defender: defender, typeChart: typeChart, recentMoves: recentMoves)
        }
    }

    /// Post-pick correction pipeline. Order: immune repair -> wasted boost
    /// / re-status override -> guaranteed-KO upgrade -> redundant-status
    /// downgrade. Each step is a no-op when its precondition isn't met.
    ///
    /// The pipeline exists so an LLM pick (or a heuristic pick in an edge
    /// case) can't make an obviously bad play:
    /// 1. **Immune repair:** if the target is immune to the pick's type,
    ///    use `fallback`. This checks the type regardless of damage class,
    ///    so a Normal-type status move is also replaced against a Ghost.
    /// 2. **Wasted boost / re-status:** a non-damaging boost while any stat
    ///    is already at +2, or any move carrying an ailment while the target
    ///    already has a status, is swapped for the damaging move with the
    ///    highest power x type multiplier.
    /// 3. **KO upgrade:** if the pick wouldn't KO but another move would
    ///    (per ``DamageCalculator/guaranteedKO(attacker:defender:moves:typeChart:accuracyFloor:)``),
    ///    take the KO.
    /// 4. **Redundant status:** a pure status-inflicting move against an
    ///    already-statused target becomes the strongest damaging
    ///    alternative. Usually step 2 has handled this already; this is a
    ///    safety net for when it couldn't.
    ///
    /// - Parameter fallback: Move to use when the target is immune to the
    ///   pick. It isn't checked itself, so pass one the target can be hit
    ///   by.
    public static func adjust<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        fallback: M
    ) -> M {
        var current = pick
        current = immuneRepair(pick: current, defender: defender, typeChart: typeChart, fallback: fallback)
        current = phaseAdjust(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart)
        current = koOverride(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart)
        current = statusRedundancyOverride(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart)
        return current
    }
}

// MARK: - Private
private extension MoveStrategy {

    static func immuneRepair<M: MoveData>(
        pick: M,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        fallback: M
    ) -> M {
        let eff = typeChart.multiplier(attacking: pick.typeName, defenders: defender.typeNames)
        return (eff == 0 && fallback.name != pick.name) ? fallback : pick
    }

    static func phaseAdjust<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> M {
        let alreadyBoosted = attacker.statStages.values.contains { $0 >= 2 }
        let wastedBoost = (pick.power ?? 0) == 0 && pick.statChangeDeltas.contains { $0 > 0 } && alreadyBoosted
        let wastedStatus = pick.ailment != "none" && defender.status != .none
        guard wastedBoost || wastedStatus else { return pick }
        return fallbackDamageMove(from: moves, defender: defender, typeChart: typeChart) ?? pick
    }

    static func koOverride<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> M {
        let pickDamage = DamageCalculator.estimateDamage(move: pick, attacker: attacker, defender: defender, typeChart: typeChart)
        guard pickDamage < defender.currentHP else { return pick }
        guard let killer = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender, moves: moves, typeChart: typeChart
        ), killer.name != pick.name else { return pick }
        return killer
    }

    static func statusRedundancyOverride<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> M {
        guard pick.ailment != "none", (pick.power ?? 0) == 0, defender.status != .none else { return pick }
        let alternatives = moves.filter { $0.name != pick.name }
        return DamageCalculator.strongestMove(
            attacker: attacker, defender: defender, moves: alternatives, typeChart: typeChart
        )?.move ?? pick
    }

    /// Cheap "hit them with something" choice: ranks damaging moves by base
    /// power x type multiplier only, ignoring stats, stages and STAB.
    static func fallbackDamageMove<M: MoveData>(
        from moves: [M],
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> M? {
        moves.compactMap { move -> (M, Double)? in
            guard let power = move.power, power > 0 else { return nil }
            let eff = typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames)
            guard eff > 0 else { return nil }
            return (move, Double(power) * eff)
        }
        .max { $0.1 < $1.1 }?.0
    }
}
