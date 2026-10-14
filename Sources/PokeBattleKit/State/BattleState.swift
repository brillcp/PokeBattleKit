import Foundation

/// Snapshot of an in-flight battle. Mutated by
/// ``BattleEngine/resolveRound(playerMove:opponentMove:)`` once per turn.
///
/// A plain value: copies are independent, and it's `Sendable`, so it can be
/// handed to an AI running on another actor without sharing mutable state.
/// A new state always starts in the move-selection phase.
public struct BattleState: Sendable {
    public var player: Combatant
    public var opponent: Combatant
    /// Internal so hosts can't bypass the engine's phase rules. Hosts learn
    /// that the battle is over from ``Event/ended(winner:)``.
    var phase: Phase = .selectingMove

    public init(player: Combatant, opponent: Combatant) {
        self.player = player
        self.opponent = opponent
    }
}
