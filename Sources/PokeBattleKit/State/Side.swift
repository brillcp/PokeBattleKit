import Foundation

/// Which side of the battle a combatant or event belongs to. Raw values
/// ("player", "opponent") are the encoded form in ``Event`` JSON.
public enum Side: String, Hashable, Sendable, Codable {
    case player
    case opponent

    public var opposite: Side { self == .player ? .opponent : .player }
}
