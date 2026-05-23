/// Deterministic AI for in-battle move selection. Owns the heuristic
/// fallback used when the LLM is unavailable and the post-pick correction
/// pipeline applied to every chosen move regardless of source.
public enum MoveStrategy {

    /// Highest-scoring move accounting for damage, recency, and low-HP bias.
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
