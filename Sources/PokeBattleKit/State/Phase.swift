import Foundation

/// Battle engine phase state machine. Driven by `Engine`; not part
/// of the public surface.
enum Phase: Sendable {
    case selectingMove
    case resolving
    case ended(winner: Side?)
}
