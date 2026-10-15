import Foundation

/// Status ailments a combatant can have. A combatant has at most one at a
/// time, and a new ailment only lands on a ``none`` target.
///
/// Effects in ``BattleEngine``:
/// - ``paralysis``: speed halved, 25% chance each turn to be fully paralyzed.
/// - ``burn``: physical damage halved, loses 1/16 max HP each round.
/// - ``poison``: loses 1/8 max HP each round. Toxic's bad poison is also
///   ``poison``, with ``Combatant/toxicCounter`` escalating the damage
///   from 1/16 by 1/16 each round.
/// - ``sleep``: can't act until the sleep counter runs out.
/// - ``freeze``: can't act; each turn there's a 20% chance to thaw out
///   first, and a Fire-type attack thaws it immediately.
public enum Status: String, Sendable, Codable {
    case none
    case paralysis
    case burn
    case poison
    case sleep
    case freeze

    /// Short badge text ("PAR", "BRN", ...); empty for ``none``.
    public var displayName: String {
        switch self {
        case .none: return ""
        case .paralysis: return "PAR"
        case .burn: return "BRN"
        case .poison: return "PSN"
        case .sleep: return "SLP"
        case .freeze: return "FRZ"
        }
    }

    /// Types that can never have this status (Gen VI+ rules): Electric
    /// can't be paralyzed, Fire can't be burned, Ice can't be frozen, and
    /// Poison and Steel can't be poisoned. Sleep has no type immunity.
    public var immuneTypes: Set<String> {
        switch self {
        case .paralysis: return ["electric"]
        case .burn: return ["fire"]
        case .poison: return ["poison", "steel"]
        case .freeze: return ["ice"]
        case .sleep, .none: return []
        }
    }

    /// Whether a Pokémon with `typeNames` can never have this status.
    public func isImmune(typeNames: [String]) -> Bool {
        !immuneTypes.isDisjoint(with: typeNames)
    }

    /// Adjective for battle text, e.g. "Pikachu is paralyzed".
    public var label: String {
        switch self {
        case .none: return "healthy"
        case .paralysis: return "paralyzed"
        case .burn: return "burned"
        case .poison: return "poisoned"
        case .sleep: return "asleep"
        case .freeze: return "frozen"
        }
    }
}

// MARK: - Internal

extension Status {
    /// Maps a PokeAPI ailment name. Ailments the engine doesn't model
    /// (confusion, trap, ...) become ``none`` and are ignored.
    init(ailment: String) {
        switch ailment {
        case "paralysis": self = .paralysis
        case "burn": self = .burn
        case "poison", "bad-poison": self = .poison
        case "sleep": self = .sleep
        case "freeze": self = .freeze
        default: self = .none
        }
    }
}
