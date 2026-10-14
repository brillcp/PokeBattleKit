import Foundation

/// One side of a fight with identity, stats, and mutable in-battle state.
///
/// Built from any ``PokemonData`` plus its ``MoveSnapshot`` loadout.
/// Stats are the species' base stats used directly (missing ones default to
/// 50); there are no levels, IVs, EVs or natures. `Codable`, so a host can
/// persist a battle mid-fight and restore it later.
public struct Combatant: Sendable, Codable {
    public let id: Int
    public let name: String
    public let frontSpriteURL: String
    public let backSpriteURL: String?
    public let typeNames: [String]
    public let maxHP: Int
    public let attack: Int
    public let defense: Int
    public let specialAttack: Int
    public let specialDefense: Int
    public let speed: Int
    public var currentHP: Int
    public var status: Status
    /// Sleep counter, decremented each time the combatant tries to act while
    /// asleep; it wakes (and acts) when this reaches 0.
    public var sleepTurns: Int = 0
    /// Stat stages in -6...+6, keyed by PokeAPI stat name ("attack",
    /// "special-defense", ...). Missing keys mean stage 0.
    public var statStages: [String: Int]
    public let moves: [MoveSnapshot]
    /// Set after a recharge move like Hyper Beam hits; the next action is
    /// spent recharging.
    var mustRecharge: Bool = false

    /// Creates a combatant at full HP with no status or stat stages.
    ///
    /// Max HP is `2 * baseHP + 110`, the main-series HP formula at level 100
    /// with no IVs or EVs. Paired with the level-50 damage formula, that
    /// HP pool keeps most fights going for several turns.
    ///
    /// - Parameter hpBonus: Multiplier applied to max HP, for example to
    ///   give one side a buffer. Defaults to 1.0.
    public init(
        pokemon: some PokemonData,
        moves: [MoveSnapshot],
        hpBonus: Double = 1.0
    ) {
        let stats = pokemon.statLookup
        let baseHP = stats["hp"] ?? 50
        self.id = pokemon.id
        self.name = pokemon.name
        self.frontSpriteURL = pokemon.frontSprite
        self.backSpriteURL = pokemon.backSprite
        self.typeNames = pokemon.typeNames
        self.maxHP = Int(Double(baseHP * 2 + 110) * hpBonus)
        self.currentHP = self.maxHP
        self.attack = stats["attack"] ?? 50
        self.defense = stats["defense"] ?? 50
        self.specialAttack = stats["special-attack"] ?? 50
        self.specialDefense = stats["special-defense"] ?? 50
        self.speed = stats["speed"] ?? 50
        self.status = .none
        self.statStages = [:]
        self.moves = moves
    }

    public var isFainted: Bool { currentHP <= 0 }
    public var isBoosted: Bool { statStages.values.contains { $0 > 0 } }

    /// Speed used for turn order: halved while paralyzed. Speed stat stages
    /// are not applied.
    public var effectiveSpeed: Int {
        status == .paralysis ? speed / 2 : speed
    }

    public func stage(for stat: String) -> Int { statStages[stat] ?? 0 }

    /// Adds `delta` to a stat stage, clamped to -6...+6.
    public mutating func applyStage(_ stat: String, delta: Int) {
        let next = max(-6, min(6, stage(for: stat) + delta))
        statStages[stat] = next
    }
}
