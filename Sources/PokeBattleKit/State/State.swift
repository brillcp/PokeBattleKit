import Foundation

/// Snapshot of an in-flight battle. Mutated by `Engine.resolveRound`
/// once per turn.
public struct State: Sendable {
    public var player: Combatant
    public var opponent: Combatant
    var phase: Phase = .selectingMove

    public init(player: Combatant, opponent: Combatant) {
        self.player = player
        self.opponent = opponent
    }
}
