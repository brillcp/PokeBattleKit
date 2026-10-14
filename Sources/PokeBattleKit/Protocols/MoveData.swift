import Foundation

/// Properties the battle engine reads from a move.
///
/// Conformers include the concrete ``Move`` and ``MoveSnapshot`` shipped
/// with this package and any app-side persistence model (e.g. a SwiftData
/// `@Model`) that satisfies the same shape. The protocol intentionally
/// omits `Sendable` so non-Sendable model classes can conform; convert to a
/// ``MoveSnapshot`` before handing a move to a ``Combatant`` or another
/// isolation domain.
///
/// Values follow PokeAPI conventions: names are lowercase and hyphenated
/// ("thunder-punch"), and strings like ``damageClass``, ``typeName`` and
/// ``ailment`` are PokeAPI names (`"none"` when there is no ailment).
public protocol MoveData {
    /// PokeAPI name; also the identity used for dedupe and recency checks.
    var name: String { get }
    var displayName: String { get }
    /// Base power; `nil` or 0 for moves that don't deal direct damage.
    var power: Int? { get }
    /// Hit chance in percent; `nil` means the move never misses.
    var accuracy: Int? { get }
    /// Priority bracket; higher always moves first regardless of speed.
    var priority: Int { get }
    /// "physical", "special" or "status".
    var damageClass: String { get }
    var typeName: String { get }
    var ailment: String { get }
    /// Percent chance to inflict ``ailment``; 0 on status moves means
    /// guaranteed.
    var ailmentChance: Int { get }
    /// Percent of damage dealt returned as HP (positive) or taken as recoil
    /// (negative).
    var drain: Int { get }
    /// Percent of max HP restored by healing moves.
    var healing: Int { get }
    /// Percent chance for a damaging move's secondary stat change; `nil`
    /// means it always applies.
    var effectChance: Int? { get }
    /// Stats changed by the move, parallel to ``statChangeDeltas``.
    var statChangeNames: [String] { get }
    /// Stage change for each entry in ``statChangeNames``.
    var statChangeDeltas: [Int] { get }
    var isRechargeMove: Bool { get }
    var hasSelfDebuff: Bool { get }
}

public extension MoveData {
    /// Typed ``damageClass``; unrecognized strings are treated as status.
    var damageClassKind: DamageClass {
        DamageClass(rawValue: damageClass) ?? .status
    }

    /// Single-label role used to describe and balance loadouts: "DMG",
    /// "BOOST", "DISRUPT", "HEAL" or "OTHER". Checked in that order, so a
    /// damaging move with a secondary stat boost still counts as "DMG".
    var loadoutCategory: String {
        if (power ?? 0) > 0 { return "DMG" }
        if statChangeDeltas.contains(where: { $0 > 0 }) { return "BOOST" }
        if ailment != "none" || statChangeDeltas.contains(where: { $0 < 0 }) { return "DISRUPT" }
        if healing > 0 || name == "rest" { return "HEAL" }
        return "OTHER"
    }

    // Category predicates used to build loadout buckets. Boost and disrupt
    // only consider non-damaging moves; a move can be both (Shell Smash).
    var isDamage: Bool  { (power ?? 0) > 0 }
    var isBoost: Bool   { (power ?? 0) == 0 && statChangeDeltas.contains { $0 > 0 } }
    var isDisrupt: Bool { (power ?? 0) == 0 && (ailment != "none" || statChangeDeltas.contains { $0 < 0 }) }

    /// Whether the engine can meaningfully resolve this move. Filter a
    /// species' learnset with this before building loadouts: it drops
    /// two-turn and self-KO moves and moves with no modeled effect at all
    /// (e.g. Splash, Protect, weather or hazard moves).
    var isBattleReady: Bool {
        if MoveClassification.chargingMoves.contains(name) { return false }
        if MoveClassification.selfKOMoves.contains(name) { return false }
        if (power ?? 0) > 0 { return true }
        if healing > 0 || name == "rest" { return true }
        if !statChangeNames.isEmpty { return true }
        if ailment != "none" { return true }
        return false
    }
}
