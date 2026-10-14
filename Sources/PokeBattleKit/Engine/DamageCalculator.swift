import Foundation

/// The Gen V+ damage formula (as documented on Bulbapedia), plus
/// deterministic helpers the AI uses to reason about damage.
///
/// There are two entry points with deliberately different guarantees:
///
/// - `computeDamage` is what ``BattleEngine`` calls to resolve a hit. It
///   rolls a critical hit and the 85–100% damage spread, so it's random.
/// - ``estimateDamage(move:attacker:defender:typeChart:superEffectiveCap:)``
///   uses the same formula without crit, random roll, or burn, so it's
///   deterministic. It equals the *highest* non-critical roll the engine can
///   produce, which makes AI decisions repeatable and testable.
///
/// Simplifications relative to the games, shared by both:
/// - Level is fixed at 50 for everyone.
/// - `A` and `D` are the combatants' raw *base* stats (no IVs, EVs, natures
///   or level scaling), multiplied by the current stat-stage multiplier.
/// - The type multiplier is capped at 1.5 when super effective (house rule,
///   see `superEffectiveCap`), so a 4x weakness hits like a 2x one.
/// - Everything is computed in floating point and truncated once at the end,
///   rather than floored after each step, so results can differ from the
///   cartridge by a point or two.
public enum DamageCalculator {

    /// Full damage computation with all modifiers. Used internally by
    /// ``BattleEngine`` when resolving a hit; callers must have already
    /// excluded status moves and moves without positive power.
    ///
    /// Formula per Bulbapedia:
    /// `((2*Level/5+2) * Power * A/D) / 50 + 2`
    /// `* Critical * random(0.85-1.0) * STAB * Type * Burn`
    ///
    /// With `Level` = 50 the first factor is a constant 22. The modifiers:
    /// - **Critical:** 1-in-32 chance, 1.5x. Unlike the games, a crit does
    ///   not ignore stat stages.
    /// - **Random:** uniform in 0.85...1.0, the classic damage spread.
    /// - **STAB:** 1.5x when the move's type matches one of the attacker's
    ///   types.
    /// - **Type:** product over the defender's types from `typeChart`;
    ///   super-effective values are capped at `superEffectiveCap` (default
    ///   1.5) to prevent runaway one-shots. Resisted and immune values are
    ///   not touched.
    /// - **Burn:** halves physical damage dealt by a burned attacker.
    ///
    /// - Returns: The damage (0 against an immune target, otherwise at least
    ///   1), the *uncapped* type multiplier so UIs can still say "It's super
    ///   effective!" for a 4x hit, and whether the hit was critical.
    static func computeDamage(
        power: Int,
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        superEffectiveCap: Double = 1.5
    ) -> (damage: Int, effectiveness: Double, crit: Bool) {
        let level = 50.0
        let isSpecial = move.damageClassKind == .special

        let atkStatName = isSpecial ? "special-attack" : "attack"
        let defStatName = isSpecial ? "special-defense" : "defense"
        let atkBase = isSpecial ? attacker.specialAttack : attacker.attack
        let defBase = isSpecial ? defender.specialDefense : defender.defense
        let atk = Double(atkBase) * statStageMultiplier(attacker.stage(for: atkStatName))
        let def = Double(defBase) * statStageMultiplier(defender.stage(for: defStatName))

        let stab = attacker.typeNames.contains(move.typeName) ? 1.5 : 1.0
        let rawType = typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames)
        let typeMult: Double
        if rawType == 0 {
            typeMult = 0
        } else if rawType > 1 {
            typeMult = min(rawType, superEffectiveCap)
        } else {
            typeMult = rawType
        }
        let crit = Double.random(in: 0..<1) < (1.0 / 32.0)
        let critMult = crit ? 1.5 : 1.0
        let randVar = Double.random(in: 0.85...1.0)
        let burnPenalty = (attacker.status == .burn && !isSpecial) ? 0.5 : 1.0

        let base = ((2.0 * level / 5.0 + 2.0) * Double(power) * atk / def) / 50.0 + 2.0
        let total = base * stab * typeMult * critMult * randVar * burnPenalty
        let damage = typeMult == 0 ? 0 : max(1, Int(total))
        return (damage, rawType, crit)
    }

    /// Deterministic damage estimate (no randomness, no crit) for AI scoring.
    ///
    /// Uses the same formula, stat stages, STAB and capped type multiplier
    /// as the engine, with the random factor fixed at 1.0. The result is the
    /// maximum non-critical damage; the engine's actual roll lands between
    /// roughly 85% and 100% of it. The burn penalty is not applied, so the
    /// estimate overstates a burned attacker's physical damage.
    ///
    /// `typeChart` is the sole input for type effectiveness; callers cannot
    /// pass arbitrary multipliers. Status-class moves, moves without positive
    /// power, and moves the defender is immune to return 0.
    public static func estimateDamage(
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        superEffectiveCap: Double = 1.5
    ) -> Int {
        guard let power = move.power, power > 0 else { return 0 }
        guard move.damageClassKind != .status else { return 0 }
        let effectiveness = typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames)
        guard effectiveness > 0 else { return 0 }

        let isSpecial = move.damageClassKind == .special
        let atkStatName = isSpecial ? "special-attack" : "attack"
        let defStatName = isSpecial ? "special-defense" : "defense"
        let atkBase = isSpecial ? attacker.specialAttack : attacker.attack
        let defBase = isSpecial ? defender.specialDefense : defender.defense
        let atk = Double(atkBase) * statStageMultiplier(attacker.stage(for: atkStatName))
        let def = Double(defBase) * statStageMultiplier(defender.stage(for: defStatName))

        let stab = attacker.typeNames.contains(move.typeName) ? 1.5 : 1.0
        let typeMult = effectiveness > 1 ? min(effectiveness, superEffectiveCap) : effectiveness

        let base = ((2.0 * 50.0 / 5.0 + 2.0) * Double(power) * atk / def) / 50.0 + 2.0
        return Int(base * stab * typeMult)
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
    /// ``estimateDamage(move:attacker:defender:typeChart:superEffectiveCap:)``,
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
