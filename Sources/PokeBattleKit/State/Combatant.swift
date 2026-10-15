import Foundation

/// One side of a fight with identity, stats, and mutable in-battle state.
///
/// Built from any ``PokemonData`` plus its ``MoveSnapshot`` loadout and the
/// ``BattleRules``. Every combatant fights at the rules' ``level`` with
/// perfect IVs, no EVs and a neutral nature, the usual baseline for even
/// competitive play, and its stats come from the main-series formulas
/// (missing base stats default to 50).
///
/// Max HP is the real HP times ``BattleRules/hpMultiplier``, which the
/// rules derive from how long a fight should last. Anything the games
/// define as a share of max HP (healing, Rest, burn and poison damage) uses
/// the real HP, ``baseMaxHP``, so it keeps its real-game size relative to
/// attacks.
///
/// `Codable`, so a host can persist a battle mid-fight and restore it later.
public struct Combatant: Sendable, Codable {

    public let id: Int
    public let name: String
    public let frontSpriteURL: String
    public let backSpriteURL: String?
    public let typeNames: [String]
    /// The level stats and damage are computed at.
    public let level: Int
    /// Weight in hectograms, if known.
    public let weight: Int?
    /// Battle HP: the real HP times ``BattleRules/hpMultiplier`` (and any
    /// `hpBonus`).
    public let maxHP: Int
    /// The real HP at ``level``. Healing, Rest, and burn and poison damage
    /// are fractions of this rather than of ``maxHP``.
    public let baseMaxHP: Int
    /// Actual stats at ``level``, not the species' base stats.
    public let attack: Int
    public let defense: Int
    public let specialAttack: Int
    public let specialDefense: Int
    public let speed: Int
    public var currentHP: Int
    public var status: Status
    /// Turns left asleep. Each attempt to act while it's above 0 is skipped
    /// and counts it down; the attempt after it reaches 0 wakes up and acts.
    /// So a counter of N costs exactly N turns.
    public var sleepTurns: Int = 0
    /// Toxic's escalating counter. 0 for regular poison; while badly
    /// poisoned it's N on the Nth end-of-round tick, which deals N/16 of max
    /// HP (capped at 15/16).
    public var toxicCounter: Int = 0
    /// Stat stages in -6...+6, keyed by PokeAPI stat name ("attack",
    /// "special-defense", ...). Missing keys mean stage 0.
    public var statStages: [String: Int]
    public internal(set) var moves: [MoveSnapshot]
    /// Rounds this combatant has taken an action in (including ones lost to
    /// sleep, paralysis or flinching). Fake Out only works while it's 0.
    public internal(set) var turnsActive: Int = 0
    /// Set after a recharge move like Hyper Beam hits; the next action is
    /// spent recharging.
    var mustRecharge: Bool = false

    /// Creates a combatant at full HP with no status or stat stages.
    ///
    /// Stats use the main-series formulas with 31 IVs, 0 EVs and a neutral
    /// nature; at level 50 these simplify to `base + 75` for HP and
    /// `base + 20` for the others.
    ///
    /// - Parameters:
    ///   - rules: Level and battle length. Pass the same rules to both
    ///     sides.
    ///   - level: This combatant's level; defaults to the rules' level. Pass
    ///     ``BattleRules/opponentLevel(for:)`` for an AI opponent. The HP
    ///     multiplier always comes from the rules' base level, so a level
    ///     gap makes the higher-level side genuinely stronger.
    ///   - hpBonus: Extra multiplier on max HP, for example to give one side
    ///     a buffer. Defaults to 1.0; leave it there for an even fight.
    public init(
        pokemon: some PokemonData,
        moves: [MoveSnapshot],
        rules: BattleRules = .standard,
        level: Int? = nil,
        hpBonus: Double = 1.0
    ) {
        let level = level ?? rules.level
        let stats = pokemon.statLookup
        self.id = pokemon.id
        self.name = pokemon.name
        self.frontSpriteURL = pokemon.frontSprite
        self.backSpriteURL = pokemon.backSprite
        self.typeNames = pokemon.typeNames
        self.level = level
        self.weight = pokemon.weightInHectograms
        self.baseMaxHP = Self.hpStat(base: stats["hp"] ?? 50, level: level)
        self.maxHP = Int(Double(baseMaxHP) * rules.hpMultiplier * hpBonus)
        self.currentHP = self.maxHP
        self.attack = Self.stat(base: stats["attack"] ?? 50, level: level)
        self.defense = Self.stat(base: stats["defense"] ?? 50, level: level)
        self.specialAttack = Self.stat(base: stats["special-attack"] ?? 50, level: level)
        self.specialDefense = Self.stat(base: stats["special-defense"] ?? 50, level: level)
        self.speed = Self.stat(base: stats["speed"] ?? 50, level: level)
        self.status = .none
        self.statStages = [:]
        self.moves = moves
    }

    /// HP: `(2 * base + IV + EV / 4) * level / 100 + level + 10`.
    public static func hpStat(base: Int, level: Int, iv: Int = 31) -> Int {
        (2 * base + iv) * level / 100 + level + 10
    }

    /// Any other stat: `(2 * base + IV + EV / 4) * level / 100 + 5`.
    public static func stat(base: Int, level: Int, iv: Int = 31) -> Int {
        (2 * base + iv) * level / 100 + 5
    }

    public var isFainted: Bool { currentHP <= 0 }
    public var isBoosted: Bool { statStages.values.contains { $0 > 0 } }
    /// Poisoned by Toxic rather than regular poison.
    public var isBadlyPoisoned: Bool { status == .poison && toxicCounter > 0 }

    /// Speed used for turn order: the speed stat scaled by its stat stage
    /// (Agility's +2 doubles it), then halved while paralyzed.
    public var effectiveSpeed: Int {
        let staged = Int(Double(speed) * statStageMultiplier(stage(for: "speed")))
        return status == .paralysis ? staged / 2 : staged
    }

    public func stage(for stat: String) -> Int { statStages[stat] ?? 0 }

    /// The stat named by its PokeAPI name ("attack", "special-defense", ...).
    public func statValue(_ stat: String) -> Int {
        switch stat {
        case "attack": attack
        case "defense": defense
        case "special-attack": specialAttack
        case "special-defense": specialDefense
        case "speed": speed
        default: 0
        }
    }

    /// A copy whose ``moves`` are only those named in `moveNames`, for AI
    /// reasoning with the information a player would have: an opponent's
    /// moves become known as they're used. With no known moves the AI's
    /// scoring assumes a generic same-type attack.
    public func knowing(onlyMoves moveNames: some Sequence<String>) -> Combatant {
        let known = Set(moveNames)
        var copy = self
        copy.moves = moves.filter { known.contains($0.name) }
        return copy
    }

    /// Adds `delta` to a stat stage, clamped to -6...+6.
    public mutating func applyStage(_ stat: String, delta: Int) {
        let next = max(-6, min(6, stage(for: stat) + delta))
        statStages[stat] = next
    }
}
