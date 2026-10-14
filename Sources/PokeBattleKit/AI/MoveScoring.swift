/// Move-evaluation primitive used by both move-pick and loadout-pick
/// strategies. Mixes damage estimates with heuristic weights for status
/// effects, stat changes, and move quirks (self-debuff, recharge,
/// priority). Higher score = better for the fighter.
///
/// Scores are deterministic: damage comes from
/// ``DamageCalculator/estimateDamage(move:attacker:defender:typeChart:superEffectiveCap:)``
/// and everything else is a fixed weight from ``Weights``. A damaging move
/// scores roughly its expected HP damage (so tens of points), and the
/// support weights are tuned to sit on the same scale, which is what lets a
/// well-timed status move beat a weak attack.
public enum MoveScoring {

    /// Context-free score of `move` for `fighter` against `opponent`, used
    /// for ranking loadout candidates.
    ///
    /// Damaging moves are scored on damage alone (their secondary effects
    /// are ignored):
    /// - expected damage (estimate x accuracy),
    /// - +``Weights/koBonus`` if the estimate KOs from current HP, plus
    ///   +``Weights/nearKOBonus`` if it takes at least 65% of it (so a KO
    ///   earns both),
    /// - x``Weights/resistedMult`` when resisted,
    /// - -``Weights/selfDebuffPenalty`` for drawback moves like Overheat,
    /// - +``Weights/priorityBonus`` for priority moves,
    /// - x``Weights/rechargeMult`` for recharge moves, which effectively
    ///   cost two turns.
    ///
    /// Status-class and zero-power moves are scored by what they do: the
    /// ailment, healing, and each stat change are scored separately and
    /// summed (see the `Weights` groups below).
    ///
    /// Moves that can't work at all (a damaging move the target is immune
    /// to, or Venom Drench against an unpoisoned target) get
    /// ``Weights/disallowed`` so they sort to the bottom. Type immunity is
    /// not checked for non-damaging moves.
    public static func score(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        if MoveClassification.requiresPoisonedTarget.contains(move.name),
           opponent.status != .poison {
            return Weights.disallowed
        }
        if move.isDamage, move.damageClassKind != .status {
            return damageScore(move: move, fighter: fighter, opponent: opponent, typeChart: typeChart)
        }
        return supportScore(move: move, fighter: fighter, opponent: opponent)
    }

    /// In-battle score layering recency, recharge, and HP-aware bonuses
    /// on top of the base score. `recentMoves` is the rolling window of
    /// move names the AI has picked on prior turns (newest last).
    ///
    /// Adjustments on top of ``score(move:fighter:opponent:typeChart:)``:
    /// - **Recency escalation.** Repeating the same move is penalized more
    ///   the longer the current streak: ``Weights/repeatFirst``,
    ///   ``Weights/repeatSecond`` and ``Weights/repeatThird`` (18 / 40 / 65)
    ///   for a move used on the last 1 / 2 / 3+ turns in a row. A move used
    ///   earlier in `recentMoves` but not last turn loses a flat
    ///   ``Weights/usedRecently``. Without this the
    ///   deterministic scorer would spam its single best move, which plays
    ///   predictably and looks robotic; the steep curve still lets a
    ///   dominant move repeat now and then.
    /// - **Back-to-back recharge.** A recharge move scores only 20% when any
    ///   recharge move is in the window, to avoid chaining lost turns.
    /// - **Wasted boosts.** Non-damaging moves lose points for each raise to
    ///   a stat already at +2 or higher.
    /// - **Redundant status.** Moves carrying an ailment lose points when
    ///   the defender already has a status, since it can't stack.
    /// - **Low HP (30% or less).** Healing (and Rest) gets a large bonus, and
    ///   so do damaging priority moves, so a nearly-fainted AI tries to
    ///   recover or get one last hit in before it's KO'd.
    public static func inBattleScore(
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String]
    ) -> Double {
        var score = Self.score(move: move, fighter: attacker, opponent: defender, typeChart: typeChart)

        // Length of the current streak of this move, looking back at most
        // four turns.
        let consecutiveUses = recentMoves.suffix(4).reversed()
            .prefix(while: { $0 == move.name }).count
        switch consecutiveUses {
        case 3...: score -= Weights.repeatThird
        case 2:    score -= Weights.repeatSecond
        case 1:    score -= Weights.repeatFirst
        default:
            if recentMoves.contains(move.name) { score -= Weights.usedRecently }
        }

        if move.isRechargeMove,
           recentMoves.contains(where: { MoveClassification.rechargeMoves.contains($0) }) {
            score *= Weights.rechargeRecentMult
        }

        if (move.power ?? 0) == 0 {
            for (index, stat) in move.statChangeNames.enumerated() where index < move.statChangeDeltas.count {
                if move.statChangeDeltas[index] > 0, attacker.stage(for: stat) >= 2 {
                    score -= Weights.wastedBoostPenalty
                }
            }
        }

        if defender.status != .none, move.ailment != "none" { score -= Weights.redundantStatusPenalty }

        let hpFraction = Double(attacker.currentHP) / Double(max(1, attacker.maxHP))
        if hpFraction <= 0.30 {
            if move.healing > 0 || move.name == "rest" { score += Weights.lowHPHealBonus }
            if move.priority > 0, (move.power ?? 0) > 0 { score += Weights.lowHPPriorityBonus }
        }

        return score
    }

    /// Tunable weights collected in one place so the scoring functions
    /// read as descriptions, not magic constants.
    ///
    /// Additive weights are in "HP-damage-equivalent" points; `...Mult`
    /// values multiply the score. Paired weights (e.g. `paralysisFaster` /
    /// `paralysisSlower`) encode when an effect matters: each pair's larger
    /// value applies when the effect directly addresses the matchup.
    public enum Weights {
        /// Sentinel for moves that can't work; far below any real score.
        public static let disallowed: Double      = -100
        // Damaging moves. A KO is worth far more than the raw HP it removes.
        public static let koBonus: Double         = 55
        public static let nearKOBonus: Double     = 18
        /// Applied on top of the halved damage already in the estimate, so
        /// resisted moves are only picked when nothing better exists.
        public static let resistedMult: Double    = 0.4
        public static let selfDebuffPenalty: Double = 18
        public static let priorityBonus: Double   = 8
        public static let rechargeMult: Double    = 0.45

        // Healing: more valuable when the opponent has more max HP, i.e.
        // when the fight is likely to be a long one.
        public static let healingVsBulky: Double  = 16
        public static let healingDefault: Double  = 8

        /// Floor (percent) for the ailment chance used in scoring. PokeAPI
        /// reports 0 for most guaranteed status moves, so without a floor
        /// they would score nothing. With it they're credited a
        /// conservative 60%; higher reported chances are used as-is.
        public static let statusMinChance: Int    = 60
        // Ailments, scaled by the chance above. Paralysis matters most when
        // the opponent outspeeds us, burn when it's a physical attacker,
        // poison when it out-HPs us (chip damage pays off in long fights).
        public static let paralysisFaster: Double = 28
        public static let paralysisSlower: Double = 12
        public static let burnPhysical: Double    = 24
        public static let burnSpecial: Double     = 10
        public static let poisonBulky: Double     = 18
        public static let poisonFrail: Double     = 8
        public static let sleep: Double           = 22
        public static let statusOther: Double     = 4

        // Stat raises, per stage. Offensive boosts count when they raise
        // the fighter's stronger attacking stat; a Speed boost counts when
        // the fighter is currently slower (flat, not per stage); defensive
        // boosts count more against an opponent with more max HP.
        public static let statBoostMatching: Double   = 10
        public static let statBoostMismatch: Double   = 2
        public static let statBoostSpeedSlow: Double  = 16
        public static let statBoostSpeedFast: Double  = 2
        public static let statBoostDefVsTank: Double  = 7
        public static let statBoostDefVsFrail: Double = 4
        public static let statBoostDefault: Double    = 4

        // Stat drops on the opponent, per stage. Defense drops count when
        // they help the fighter's stronger attacking stat; Speed drops when
        // the opponent is currently faster.
        public static let statDebuffMatching: Double = 8
        public static let statDebuffMismatch: Double = 3
        public static let statDebuffDefault: Double  = 4

        // In-battle only (see `inBattleScore`). Recency penalties escalate
        // with streak length; low-HP bonuses are large so they can outweigh
        // a moderate attack.
        public static let repeatFirst: Double         = 18
        public static let repeatSecond: Double        = 40
        public static let repeatThird: Double         = 65
        public static let usedRecently: Double        = 15
        public static let rechargeRecentMult: Double  = 0.2
        public static let wastedBoostPenalty: Double   = 18
        public static let redundantStatusPenalty: Double = 25
        public static let lowHPHealBonus: Double      = 35
        public static let lowHPPriorityBonus: Double  = 20
    }
}

// MARK: - Private
private extension MoveScoring {

    /// See ``score(move:fighter:opponent:typeChart:)`` for the breakdown.
    static func damageScore(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        let effectiveness = typeChart.multiplier(attacking: move.typeName, defenders: opponent.typeNames)
        guard effectiveness > 0 else { return Weights.disallowed }
        let accuracy = Double(move.accuracy ?? 100) / 100
        let estimated = Double(DamageCalculator.estimateDamage(
            move: move, attacker: fighter, defender: opponent, typeChart: typeChart
        ))
        var score = estimated * accuracy
        if estimated >= Double(opponent.currentHP) { score += Weights.koBonus }
        if estimated >= Double(opponent.currentHP) * 0.65 { score += Weights.nearKOBonus }
        if effectiveness < 1, effectiveness > 0 { score *= Weights.resistedMult }
        if move.hasSelfDebuff { score -= Weights.selfDebuffPenalty }
        if move.priority > 0 { score += Weights.priorityBonus }
        if move.isRechargeMove { score *= Weights.rechargeMult }
        return score
    }

    static func supportScore(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        var score = 0.0
        if move.ailment != "none" {
            score += statusScore(ailment: move.ailment, chance: move.ailmentChance, fighter: fighter, opponent: opponent)
        }
        if move.healing > 0 || move.name == "rest" {
            score += opponent.maxHP > fighter.maxHP ? Weights.healingVsBulky : Weights.healingDefault
        }
        for (index, stat) in move.statChangeNames.enumerated() where index < move.statChangeDeltas.count {
            score += statChangeScore(stat: stat, delta: move.statChangeDeltas[index], fighter: fighter, opponent: opponent)
        }
        return score
    }

    /// Value of inflicting `ailment`, scaled by its (floored) chance.
    static func statusScore(
        ailment: String,
        chance: Int,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        let factor = Double(max(chance, Weights.statusMinChance)) / 100
        switch ailment {
        case "paralysis":
            return (opponent.effectiveSpeed > fighter.effectiveSpeed ? Weights.paralysisFaster : Weights.paralysisSlower) * factor
        case "burn":
            return (opponent.attack >= opponent.specialAttack ? Weights.burnPhysical : Weights.burnSpecial) * factor
        case "poison":
            return (opponent.maxHP >= fighter.maxHP ? Weights.poisonBulky : Weights.poisonFrail) * factor
        case "sleep":
            return Weights.sleep * factor
        default:
            return Weights.statusOther * factor
        }
    }

    /// Value of one stat change. Positive deltas are treated as raises on
    /// the fighter and negative ones as drops on the opponent, matching the
    /// engine's default targeting. Self-inflicted drops (Shell Smash) are
    /// therefore scored as if they hit the opponent.
    static func statChangeScore(
        stat: String,
        delta: Int,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        guard delta != 0 else { return 0 }
        let magnitude = Double(abs(delta))
        if delta > 0 {
            switch stat {
            case "speed":
                return fighter.effectiveSpeed > opponent.effectiveSpeed ? Weights.statBoostSpeedFast : Weights.statBoostSpeedSlow
            case "attack":
                return fighter.attack >= fighter.specialAttack ? magnitude * Weights.statBoostMatching : magnitude * Weights.statBoostMismatch
            case "special-attack":
                return fighter.specialAttack >= fighter.attack ? magnitude * Weights.statBoostMatching : magnitude * Weights.statBoostMismatch
            case "defense", "special-defense":
                return opponent.maxHP >= fighter.maxHP ? magnitude * Weights.statBoostDefVsTank : magnitude * Weights.statBoostDefVsFrail
            default:
                return magnitude * Weights.statBoostDefault
            }
        }
        switch stat {
        case "defense":
            return fighter.attack >= fighter.specialAttack ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        case "special-defense":
            return fighter.specialAttack >= fighter.attack ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        case "speed":
            return opponent.effectiveSpeed > fighter.effectiveSpeed ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        default:
            return magnitude * Weights.statDebuffDefault
        }
    }
}
