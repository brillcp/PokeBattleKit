/// AI for in-battle move selection: the heuristic pick and the post-pick
/// correction pipeline, applied to every chosen move whatever picked it
/// (this heuristic, a player's assistant, or anything else).
///
/// The intended flow each turn:
///
/// ```swift
/// guard let pick = MoveStrategy.heuristicPick(
///     attacker: ai, defender: player, moves: ai.moves,
///     typeChart: chart, recentMoves: aiHistory) else { return }
/// let final = MoveStrategy.adjust(
///     pick: pick, attacker: ai, defender: player,
///     moves: ai.moves, typeChart: chart, fallback: safeMove)
/// ```
///
/// ``adjust(pick:attacker:defender:moves:typeChart:fallback:)`` is
/// deterministic. ``heuristicPick(attacker:defender:moves:typeChart:recentMoves:difficulty:)``
/// is too on ``Difficulty/hard``; on the other difficulties it picks at
/// random among the near-best moves.
public enum MoveStrategy {

    /// Move choice by
    /// ``MoveScoring/inBattleScore(move:attacker:defender:typeChart:recentMoves:)``
    /// at the given difficulty. Returns `nil` only if `moves` is empty.
    ///
    /// - ``Difficulty/hard``: the highest score; ties go to the earliest move.
    /// - ``Difficulty/fair``: a random move among those scoring within 10%
    ///   (and at least 3 points) of the best, weighted by score, so the AI
    ///   varies its play between near-equal options but never throws.
    /// - ``Difficulty/easy``: a uniformly random move among those within 35%
    ///   of the best, so it often settles for a decent move.
    public static func heuristicPick<M: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String],
        difficulty: Difficulty = .fair
    ) -> M? {
        var generator = SystemRandomNumberGenerator()
        return heuristicPick(
            attacker: attacker, defender: defender, moves: moves, typeChart: typeChart,
            recentMoves: recentMoves, difficulty: difficulty, using: &generator
        )
    }

    /// ``heuristicPick(attacker:defender:moves:typeChart:recentMoves:difficulty:)``
    /// with an explicit random number generator, for reproducible tests.
    public static func heuristicPick<M: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String],
        difficulty: Difficulty,
        using generator: inout some RandomNumberGenerator
    ) -> M? {
        let scored = moves.map { move in
            (move, MoveScoring.inBattleScore(
                move: move, attacker: attacker, defender: defender,
                typeChart: typeChart, recentMoves: recentMoves
            ))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }

        let window: Double
        switch difficulty {
        case .hard: return best.0
        case .fair: window = 0.10
        case .easy: window = 0.35
        }
        let floor = best.1 - max(abs(best.1) * window, 3)
        let candidates = scored.filter { $0.1 >= floor }
        guard candidates.count > 1 else { return best.0 }

        // Fair weights by score above the cut-off; easy picks uniformly.
        let weights = candidates.map { difficulty == .easy ? 1 : $0.1 - floor + 1 }
        var roll = Double.random(in: 0..<weights.reduce(0, +), using: &generator)
        for (candidate, weight) in zip(candidates, weights) {
            if roll < weight { return candidate.0 }
            roll -= weight
        }
        return best.0
    }

    /// Post-pick correction pipeline. Order: unusable repair -> useless
    /// support override -> guaranteed-KO upgrade. Each step is a no-op when
    /// its precondition isn't met.
    ///
    /// The pipeline exists so no pick (an external one, or a heuristic pick
    /// in an edge case) can make an obviously bad play:
    /// 1. **Unusable repair:** if the pick can't work at all (see
    ///    ``MoveScoring/isUsable(_:attacker:defender:typeChart:)``: a type
    ///    immunity, Thunder Wave into Ground, Fake Out after turn one), use
    ///    `fallback`, or the strongest attack if `fallback` can't work
    ///    either. Moves that only affect the user, like Swords Dance or
    ///    Recover, are never "immune".
    /// 2. **Useless support:** a non-damaging pick that would achieve
    ///    nothing (score of 0 or less: a heal at full HP, a status on an
    ///    already-statused target, a boost at +6) becomes the strongest
    ///    attack.
    /// 3. **KO upgrade:** if the pick wouldn't KO but another move would
    ///    (per ``DamageCalculator/guaranteedKO(attacker:defender:moves:typeChart:accuracyFloor:)``),
    ///    take the KO.
    ///
    /// "Strongest attack" means the highest expected damage, so it accounts
    /// for stats, STAB, stat stages, type and accuracy.
    ///
    /// - Parameter fallback: Move to use when the pick can't work.
    public static func adjust<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        fallback: M
    ) -> M {
        var current = pick
        current = unusableRepair(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart, fallback: fallback)
        current = uselessSupportOverride(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart)
        current = koOverride(pick: current, attacker: attacker, defender: defender, moves: moves, typeChart: typeChart)
        return current
    }

    /// The move with the highest expected damage (estimate x average roll
    /// x accuracy), or `nil` if nothing in `moves` can deal damage.
    public static func strongestAttack<M: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> M? {
        moves
            .map { ($0, MoveScoring.expectedDamage($0, attacker: attacker, defender: defender, typeChart: typeChart)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
    }
}

// MARK: - Private
private extension MoveStrategy {

    static func unusableRepair<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding,
        fallback: M
    ) -> M {
        guard !MoveScoring.isUsable(pick, attacker: attacker, defender: defender, typeChart: typeChart) else { return pick }
        if MoveScoring.isUsable(fallback, attacker: attacker, defender: defender, typeChart: typeChart) { return fallback }
        return strongestAttack(attacker: attacker, defender: defender, moves: moves, typeChart: typeChart) ?? pick
    }

    static func uselessSupportOverride<M: MoveData>(
        pick: M,
        attacker: Combatant,
        defender: Combatant,
        moves: [M],
        typeChart: some TypeEffectivenessProviding
    ) -> M {
        guard !pick.isDamage,
              MoveScoring.score(move: pick, fighter: attacker, opponent: defender, typeChart: typeChart) <= 0
        else { return pick }
        return strongestAttack(attacker: attacker, defender: defender, moves: moves, typeChart: typeChart) ?? pick
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
        // Never trade a priority pick for a slower KO: the priority move may
        // be the only way to act before the defender does.
        let usable = moves.filter {
            $0.priority >= pick.priority
                && MoveScoring.isUsable($0, attacker: attacker, defender: defender, typeChart: typeChart)
        }
        guard let killer = DamageCalculator.guaranteedKO(
            attacker: attacker, defender: defender, moves: usable, typeChart: typeChart
        ), killer.name != pick.name else { return pick }
        return killer
    }
}
