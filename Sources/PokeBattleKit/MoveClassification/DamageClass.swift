import Foundation

/// Physical, special, or status.
///
/// Physical moves pair Attack with Defense and are halved by burn; special
/// moves pair Special Attack with Special Defense; status moves deal no
/// direct damage. Raw values match PokeAPI's `damage_class` names.
public enum DamageClass: String, Sendable {
    case physical
    case special
    case status
}
