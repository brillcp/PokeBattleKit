import Foundation

/// The Gen V+ damage formula (as documented on Bulbapedia), plus
/// deterministic helpers the AI uses to reason about damage.
///
/// There are two entry points with deliberately different guarantees:
///
/// - `computeDamage` is what ``BattleEngine`` calls to resolve one hit. It
///   rolls a critical hit and the 85–100% damage spread, so it's random.
/// - ``estimateDamage(move:attacker:defender:typeChart:)`` uses the same
///   formula without crit or random roll, so it's deterministic. For a
///   single-hit move it equals the *highest* non-critical roll the engine
///   can produce, which makes AI decisions repeatable and testable.
///
/// Simplifications relative to the games, shared by both:
/// - `Level` is the attacker's ``Combatant/level``; `A` and `D` are the
///   combatants' stats at their level times the current stat-stage
///   multiplier.
/// - No abilities, items, weather or natures.
/// - Everything is computed in floating point and truncated once at the end,
///   rather than floored after each step, so results can differ from the
///   cartridge by a point or two.
public enum DamageCalculator {

    /// Critical-hit multiplier (Gen VI+).
    public static let criticalMultiplier = 1.5
    /// Same-type attack bonus.
    public static let stabMultiplier = 1.5
    /// Mean of the 85-100% damage roll.
    public static let averageRoll = 0.925

    /// The core formula, `((2*Level/5+2) * Power * A/D) / 50 + 2`, before
    /// any modifiers.
    public static func formulaDamage(level: Int, power: Int, attack: Double, defense: Double) -> Double {
        ((2.0 * Double(level) / 5.0 + 2.0) * Double(power) * attack / max(1, defense)) / 50.0 + 2.0
    }

    /// Chance of a critical hit for a move's crit stage (Gen VII+): 1/24 at
    /// stage 0, 1/8 at stage 1 (high-crit moves like Stone Edge), 1/2 at
    /// stage 2, and always at 3 or more.
    public static func criticalChance(stage: Int) -> Double {
        switch stage {
        case ...0: 1.0 / 24.0
        case 1: 1.0 / 8.0
        case 2: 0.5
        default: 1.0
        }
    }

    /// Damage of one hit with all modifiers. Used internally by
    /// ``BattleEngine`` when resolving a hit (multi-hit moves call it once
    /// per hit); callers must have already excluded status moves and moves
    /// without positive power.
    ///
    /// Formula per Bulbapedia:
    /// `((2*Level/5+2) * Power * A/D) / 50 + 2`
    /// `* Critical * random(0.85-1.0) * STAB * Type * Burn`
    ///
    /// At level 50 the first factor is 22. The modifiers:
    /// - **Critical:** chance from ``criticalChance(stage:)``, 1.5x. A crit
    ///   ignores the attacker's negative attacking stage and the defender's
    ///   positive defending stage, as in the games.
    /// - **Random:** uniform in 0.85...1.0, the classic damage spread.
    /// - **STAB:** 1.5x when the move's type matches one of the attacker's
    ///   types.
    /// - **Type:** product over the defender's types from `typeChart`, so a
    ///   double weakness is 4x.
    /// - **Burn:** halves physical damage dealt by a burned attacker.
    ///
    /// - Parameters:
    ///   - forceCritical: Overrides the crit roll, for tests.
    ///   - roll: Overrides the random factor, for tests.
    /// - Returns: The damage (0 against an immune target, otherwise at least
    ///   1), the type multiplier, and whether the hit was critical.
    static func computeDamage(
        power: Int,
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        forceCritical: Bool? = nil,
        roll: Double? = nil
    ) -> (damage: Int, effectiveness: Double, crit: Bool) {
        let typeMult = typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames)
        let crit = forceCritical ?? (Double.random(in: 0..<1) < criticalChance(stage: move.critRate))
        guard typeMult > 0 else { return (0, 0, crit) }

        let base = baseDamage(power: power, move: move, attacker: attacker, defender: defender, critical: crit)
        let critMult = crit ? criticalMultiplier : 1.0
        let randVar = roll ?? Double.random(in: 0.85...1.0)
        let total = base * stab(move: move, attacker: attacker) * typeMult * critMult * randVar
            * burnPenalty(move: move, attacker: attacker)
        return (max(1, Int(total)), typeMult, crit)
    }

    /// Deterministic damage estimate (no randomness, no crit) for AI scoring.
    ///
    /// Uses the same formula, stat stages, STAB, type multiplier and burn
    /// penalty as the engine, with the random factor fixed at 1.0. For a
    /// single-hit move the result is the maximum non-critical damage; the
    /// engine's actual roll lands between roughly 85% and 100% of it.
    /// Multi-hit moves are multiplied by ``MoveData/expectedPowerMultiple``
    /// (the expected hits, or the summed power steps of Triple Axel).
    ///
    /// `typeChart` is the sole input for type effectiveness. Status-class
    /// moves, moves without positive power, and moves the defender is
    /// immune to return 0.
    ///
    /// Situational power (Low Kick, Facade, Payback, ...) comes from
    /// ``power(of:attacker:defender:context:randomized:)`` with `context`,
    /// or the predicted context for this move when it's `nil`. Fixed-damage
    /// moves (Seismic Toss) return their fixed amount.
    public static func estimateDamage(
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        context: TurnContext? = nil
    ) -> Int {
        let move = move.resolved(for: attacker)
        guard move.isDamage, move.damageClassKind != .status else { return 0 }
        let typeMult = typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames)
        guard typeMult > 0 else { return 0 }
        let context = context ?? .predicted(move: move, attacker: attacker, defender: defender)

        switch power(of: move, attacker: attacker, defender: defender, context: context) {
        case .fixed(let amount)?:
            return amount
        case .power(let power)?:
            let base = baseDamage(power: power, move: move, attacker: attacker, defender: defender, critical: false)
            let perHit = base * stab(move: move, attacker: attacker) * typeMult * burnPenalty(move: move, attacker: attacker)
            return Int(max(1, perHit) * move.expectedPowerMultiple)
        case nil:
            return 0
        }
    }

    /// Move that lands a KO this turn, accounting for accuracy.
    ///
    /// Filters to moves whose estimated damage covers the defender's current
    /// HP and whose accuracy is at least `accuracyFloor` (85% by default;
    /// moves with `nil` accuracy never miss and count as 100%). Among those,
    /// picks the highest accuracy-weighted expected damage. Returns `nil`
    /// when no move qualifies.
    ///
    /// "Guaranteed" is relative to
    /// ``estimateDamage(move:attacker:defender:typeChart:)``,
    /// which is the top damage roll: in the engine the move can still miss or
    /// roll low and leave the defender on a sliver of HP.
    public static func guaranteedKO<Move: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [Move],
        typeChart: some TypeEffectivenessProviding,
        accuracyFloor: Double = 0.85
    ) -> Move? {
        let target = defender.currentHP
        let killers = moves.compactMap { move -> (Move, Double)? in
            let dmg = estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: typeChart)
            guard dmg >= target else { return nil }
            let accuracy = Double(move.accuracy ?? 100) / 100
            guard accuracy >= accuracyFloor else { return nil }
            return (move, Double(dmg) * accuracy)
        }
        return killers.max { $0.1 < $1.1 }?.0
    }

    /// Move with the highest estimated damage against `defender`, ignoring
    /// accuracy. Returns `nil` if no move would deal damage (zero power,
    /// status class, or the defender is immune).
    public static func strongestMove<Move: MoveData>(
        attacker: Combatant,
        defender: Combatant,
        moves: [Move],
        typeChart: some TypeEffectivenessProviding
    ) -> (move: Move, damage: Int)? {
        let scored = moves.compactMap { move -> (Move, Int)? in
            let dmg = estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: typeChart)
            return dmg > 0 ? (move, dmg) : nil
        }
        return scored.max { $0.1 < $1.1 }
    }
}

// MARK: - Private
private extension DamageCalculator {
    /// `((2*Level/5+2) * Power * A/D) / 50 + 2` with stat stages applied.
    /// A critical hit drops the attacker's negative stage and the
    /// defender's positive one.
    ///
    /// `A` and `D` are normally the attacker's (Special) Attack and the
    /// defender's (Special) Defense, except for Foul Play (the target's
    /// Attack), Body Press (the user's Defense) and Psyshock-like moves
    /// (the target's physical Defense).
    static func baseDamage(
        power: Int,
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        critical: Bool
    ) -> Double {
        let isSpecial = move.damageClassKind == .special
        // Who the attacking stat belongs to, and which stats are used.
        let attackSource = MoveClassification.usesTargetAttack.contains(move.name) ? defender : attacker
        let attackStat: String
        if MoveClassification.usesUserDefense.contains(move.name) {
            attackStat = "defense"
        } else {
            attackStat = isSpecial ? "special-attack" : "attack"
        }
        let defenseStat = isSpecial && !MoveClassification.targetsPhysicalDefense.contains(move.name)
            ? "special-defense" : "defense"

        var atkStage = attackSource.stage(for: attackStat)
        var defStage = defender.stage(for: defenseStat)
        if critical {
            atkStage = max(0, atkStage)
            defStage = min(0, defStage)
        }
        let atk = Double(attackSource.statValue(attackStat)) * statStageMultiplier(atkStage)
        let def = Double(defender.statValue(defenseStat)) * statStageMultiplier(defStage)
        return formulaDamage(level: attacker.level, power: power, attack: atk, defense: def)
    }

    static func stab(move: some MoveData, attacker: Combatant) -> Double {
        attacker.typeNames.contains(move.typeName) ? stabMultiplier : 1.0
    }

    /// Burn halves physical damage, except Facade's (Gen VI+).
    static func burnPenalty(move: some MoveData, attacker: Combatant) -> Double {
        attacker.status == .burn && move.damageClassKind == .physical && move.name != "facade" ? 0.5 : 1.0
    }
}
