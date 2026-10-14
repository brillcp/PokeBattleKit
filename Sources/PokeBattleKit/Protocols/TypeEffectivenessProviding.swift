import Foundation

/// Provides type-effectiveness multipliers for damage calculation.
///
/// ``TypeChart`` is the standard implementation. The damage calculator and
/// the AI strategies are generic over this protocol so tests can supply a
/// small fixed chart. It requires `Sendable` so a chart can be shared with
/// AI work running off the main actor.
public protocol TypeEffectivenessProviding: Sendable {
    /// Combined multiplier for `attacking` type against all `defenders` types.
    func multiplier(attacking: String, defenders: [String]) -> Double
}

public extension TypeEffectivenessProviding {
    /// Highest multiplier any of `attackerTypes` achieves against `defenderTypes`.
    ///
    /// Approximates how hard a Pokemon can hit with same-type (STAB) moves
    /// without knowing its actual moveset. ``OpponentStrategy`` uses it in
    /// both directions to judge offensive pressure on a type matchup.
    /// Returns 1.0 when `attackerTypes` is empty (and, for ``TypeChart``,
    /// when `defenderTypes` is empty).
    func bestSTABMultiplier(attackerTypes: [String], defenderTypes: [String]) -> Double {
        attackerTypes
            .map { multiplier(attacking: $0, defenders: defenderTypes) }
            .max() ?? 1.0
    }
}
