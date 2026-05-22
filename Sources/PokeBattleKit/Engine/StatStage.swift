import Foundation

private let maxStage = 6
private let base = 2.0

/// Stat stage multiplier per the standard Pokemon formula.
/// Stage 0 = 1.0x, +6 = 4.0x, -6 = 0.25x.
func statStageMultiplier(_ stage: Int) -> Double {
    let s = max(-maxStage, min(maxStage, stage))
    return s >= 0 ? (base + Double(s)) / base : base / (base - Double(s))
}
