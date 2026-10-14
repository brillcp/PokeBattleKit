import Foundation

/// Status ailments a combatant can have. A combatant has at most one at a
/// time, and a new ailment only lands on a ``none`` target.
///
/// Effects in ``BattleEngine``:
/// - ``paralysis``: speed halved, 25% chance each turn to be fully paralyzed.
/// - ``burn``: physical damage halved, loses 1/16 max HP each round.
/// - ``poison``: loses 1/8 max HP each round (Toxic is treated the same).
/// - ``sleep``: can't act until the sleep counter runs out.
public enum Status: String, Sendable, Codable {
    case none
    case paralysis
    case burn
    case poison
    case sleep

    /// Short badge text ("PAR", "BRN", ...); empty for ``none``.
    public var displayName: String {
        switch self {
        case .none: return ""
        case .paralysis: return "PAR"
        case .burn: return "BRN"
        case .poison: return "PSN"
        case .sleep: return "SLP"
        }
    }

    /// Adjective for battle text, e.g. "Pikachu is paralyzed".
    public var label: String {
        switch self {
        case .none: return "healthy"
        case .paralysis: return "paralyzed"
        case .burn: return "burned"
        case .poison: return "poisoned"
        case .sleep: return "asleep"
        }
    }
}

// MARK: - Internal

extension Status {
    /// Maps a PokeAPI ailment name. Ailments the engine doesn't model
    /// (confusion, freeze, trap, ...) become ``none`` and are ignored.
    init(ailment: String) {
        switch ailment {
        case "paralysis": self = .paralysis
        case "burn": self = .burn
        case "poison", "bad-poison": self = .poison
        case "sleep": self = .sleep
        default: self = .none
        }
    }
}
