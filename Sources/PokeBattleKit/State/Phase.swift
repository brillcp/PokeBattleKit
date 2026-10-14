import Foundation

/// Battle engine phase state machine. Driven by ``BattleEngine``; not part
/// of the public surface.
///
/// `selectingMove` -> `resolving` -> back to `selectingMove`, or to `ended`
/// once someone faints. `ended` is terminal: further rounds are ignored.
enum Phase: Sendable {
    case selectingMove
    case resolving
    case ended(winner: Side?)
}
