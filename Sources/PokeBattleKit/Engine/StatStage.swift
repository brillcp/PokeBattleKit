import Foundation

private let maxStage = 6
private let base = 2.0

/// Stat stage multiplier per the standard Pokemon formula.
///
/// Positive stages add to the numerator, negative stages to the
/// denominator: `(2 + s) / 2` for boosts and `2 / (2 - s)` for drops. So each
/// +1 adds half the base stat (+1 = 1.5x, +2 = 2x, ... +6 = 4x), while drops
/// mirror that (-1 = 0.67x, -2 = 0.5x, ... -6 = 0.25x) and can never reach
/// zero. Stage 0 = 1.0x. Inputs outside -6...+6 are clamped.
///
/// Used for attack, defense, special attack and special defense in
/// ``DamageCalculator``, and for speed in ``Combatant/effectiveSpeed`` (turn
/// order). Accuracy and evasion stages are tracked on ``Combatant`` but never
/// converted to a multiplier, so they don't change hit chance (only the AI
/// reads them, to avoid over-boosting).
func statStageMultiplier(_ stage: Int) -> Double {
    let s = max(-maxStage, min(maxStage, stage))
    return s >= 0 ? (base + Double(s)) / base : base / (base - Double(s))
}
