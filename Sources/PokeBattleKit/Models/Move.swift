import Foundation

/// A move as loaded from PokeAPI by ``PokeBattleKit/initialize()``.
///
/// Fields mirror PokeAPI's `/move/{name}` response, flattened (the `meta`
/// block's values default to "none"/0 when PokeAPI omits it). Look moves up
/// with ``PokeBattleKit/move(named:)`` or ``PokeBattleKit/allMoves``, and
/// convert to a ``MoveSnapshot`` to put them in a ``Combatant``.
public struct Move: MoveData, Codable, Hashable, Sendable {
    public let name: String
    public let power: Int?
    public let accuracy: Int?
    /// Power points. Kept for display; the engine doesn't track PP.
    public let pp: Int?
    public let priority: Int
    public let damageClass: String
    public let typeName: String
    public let ailment: String
    public let ailmentChance: Int
    public let drain: Int
    public let healing: Int
    public let effectChance: Int?
    /// PokeAPI's move category, e.g. "damage", "ailment", "net-good-stats".
    public let category: String
    public let statChangeNames: [String]
    public let statChangeDeltas: [Int]

    /// Title-cased API name, e.g. "thunder-punch" -> "Thunder Punch".
    public var displayName: String {
        name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    public var isRechargeMove: Bool {
        MoveClassification.rechargeMoves.contains(name)
    }

    public var hasSelfDebuff: Bool {
        MoveClassification.selfDebuffMoves.contains(name)
    }
}

// MARK: - Internal

extension Move {
    init(from response: APIMoveResponse) {
        self.name = response.name
        self.power = response.power
        self.accuracy = response.accuracy
        self.pp = response.pp
        self.priority = response.priority
        self.damageClass = response.damageClass.name
        self.typeName = response.type.name
        self.ailment = response.meta?.ailment.name ?? "none"
        self.ailmentChance = response.meta?.ailmentChance ?? 0
        self.drain = response.meta?.drain ?? 0
        self.healing = response.meta?.healing ?? 0
        self.effectChance = response.effectChance
        self.category = response.meta?.category.name ?? "damage"
        self.statChangeNames = response.statChanges.map(\.stat.name)
        self.statChangeDeltas = response.statChanges.map(\.change)
    }
}
