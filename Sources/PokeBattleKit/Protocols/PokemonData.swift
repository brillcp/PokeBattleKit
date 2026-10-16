import Foundation

/// Minimal Pokemon data the battle engine needs to build a combatant.
///
/// Conform your app's Pokemon model to this and pass it to
/// ``Combatant/init(pokemon:moves:rules:level:hpBonus:)``, which copies the values out;
/// like ``MoveData`` it isn't `Sendable`, so model classes can conform.
public protocol PokemonData {
    var id: Int { get }
    var name: String { get }
    var frontSprite: String { get }
    var backSprite: String? { get }
    var typeNames: [String] { get }
    /// Base stats keyed by canonical name ("hp", "attack", "defense",
    /// "special-attack", "special-defense", "speed"). Missing stats default
    /// to 50.
    var statLookup: [String: Int] { get }
    /// Weight in hectograms (PokeAPI's unit), for weight-based moves like
    /// Low Kick and Heavy Slam. Defaults to `nil` (unknown), in which case
    /// those moves use a middling power.
    var weightInHectograms: Int? { get }
}

public extension PokemonData {
    var weightInHectograms: Int? { nil }
}
