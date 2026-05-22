import Foundation

/// Which side of the battle an event applies to.
public enum Side: Hashable, Sendable {
    case player
    case opponent

    public var opposite: Side { self == .player ? .opponent : .player }
}
