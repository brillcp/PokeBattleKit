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
    /// Who the move's stat changes apply to, from PokeAPI's move target and
    /// meta category. `nil` when the move has no stat changes or the
    /// conformer doesn't know; see ``resolvedStatChangeTarget(forDelta:)``
    /// for the fallback. Defaults to `nil`.
    var statChangeTarget: StatChangeTarget? { get }
    /// Fewest and most hits for multi-hit moves like Bullet Seed (2 and 5)
    /// or Double Kick (2 and 2); `nil` for single-hit moves. Default `nil`.
    var minHits: Int? { get }
    var maxHits: Int? { get }
    /// Critical-hit stage bonus: 0 for most moves, 1 for high-crit moves
    /// like Stone Edge. Defaults to 0.
    var critRate: Int { get }
    /// Percent chance to make the target flinch (lose its action this
    /// round if it hasn't moved yet). Defaults to 0.
    var flinchChance: Int { get }
}

/// Who a move's stat changes apply to.
public enum StatChangeTarget: String, Sendable, Codable {
    /// The move's user, like Swords Dance or Close Combat's drops.
    case user
    /// The user's opponent, like Growl or Crunch's Defense drop.
    case opponent
}

public extension MoveData {
    var statChangeTarget: StatChangeTarget? { nil }
    var minHits: Int? { nil }
    var maxHits: Int? { nil }
    var critRate: Int { 0 }
    var flinchChance: Int { 0 }
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
        if isDamage { return "DMG" }
        if statChangeDeltas.contains(where: { $0 > 0 }) { return "BOOST" }
        if ailment != "none" || statChangeDeltas.contains(where: { $0 < 0 }) { return "DISRUPT" }
        if healing > 0 || name == "rest" { return "HEAL" }
        return "OTHER"
    }

    // Category predicates used to build loadout buckets. Boost and disrupt
    // only consider non-damaging moves. Boost means raising the user's own
    // stats, disrupt means a status ailment or lowering the opponent's.
    /// Deals damage: has a base power, or its power or damage is worked out
    /// from the situation (Low Kick, Seismic Toss).
    var isDamage: Bool {
        (power ?? 0) > 0
            || MoveClassification.computedPowerMoves.contains(name)
            || MoveClassification.fixedDamageMoves.contains(name)
    }

    /// Inflicts bad poison (Toxic), whose damage escalates each turn.
    var inflictsBadPoison: Bool {
        ailment == "bad-poison" || MoveClassification.badPoisonMoves.contains(name)
    }
    var isBoost: Bool {
        !isDamage && statChanges.contains { $0.delta > 0 && $0.target == .user }
    }
    var isDisrupt: Bool {
        !isDamage && (Status(ailment: ailment) != .none
            || statChanges.contains { $0.delta < 0 && $0.target == .opponent })
    }
    /// A non-damaging move that only affects its user: a heal, Rest, or
    /// stat changes on itself. Type immunities can't stop these.
    var isSelfTargeting: Bool {
        guard !isDamage, Status(ailment: ailment) == .none else { return false }
        if healing > 0 || name == "rest" { return true }
        return !statChanges.isEmpty && statChanges.allSatisfy { $0.target == .user }
    }

    /// Who a stat change of `delta` applies to. Uses ``statChangeTarget``
    /// when the data has it; otherwise infers it the way older data needs:
    /// known drawback moves (``hasSelfDebuff``) and moves that both raise
    /// and lower stats (Shell Smash) affect the user, and otherwise raises
    /// go to the user and drops to the opponent.
    func resolvedStatChangeTarget(forDelta delta: Int) -> StatChangeTarget {
        if let statChangeTarget { return statChangeTarget }
        let mixed = statChangeDeltas.contains { $0 > 0 } && statChangeDeltas.contains { $0 < 0 }
        if hasSelfDebuff || mixed { return .user }
        return delta < 0 ? .opponent : .user
    }

    /// The move's modeled stat changes (Attack, Defense, Special Attack,
    /// Special Defense, Speed) paired with who they apply to. Accuracy and
    /// evasion changes are left out because the engine doesn't model them.
    var statChanges: [(stat: String, delta: Int, target: StatChangeTarget)] {
        zip(statChangeNames, statChangeDeltas).compactMap { stat, delta in
            guard delta != 0, MoveClassification.modeledStats.contains(stat) else { return nil }
            return (stat, delta, resolvedStatChangeTarget(forDelta: delta))
        }
    }

    /// Average number of hits: 3.1 for 2-5 hit moves (the main-series odds
    /// are 35/35/15/15%), the midpoint for other ranges, 1 otherwise.
    var expectedHits: Double {
        guard let minHits, let maxHits, maxHits > 1 else { return 1 }
        if minHits == 2, maxHits == 5 { return 3.1 }
        return Double(minHits + maxHits) / 2
    }

    /// Total power over all hits as a multiple of ``power``: the expected
    /// hits, or for escalating moves like Triple Axel (power x1, x2, x3)
    /// the sum of those multipliers.
    var expectedPowerMultiple: Double {
        guard MoveClassification.escalatingMultiHitMoves.contains(name), let maxHits, maxHits > 1 else {
            return expectedHits
        }
        return Double(maxHits * (maxHits + 1) / 2)
    }

    /// Whether the engine can meaningfully resolve this move. Filter a
    /// species' learnset with this before building loadouts. It drops:
    /// - two-turn, self-KO, and other moves the engine can't resolve
    ///   faithfully (``MoveClassification/unsupportedMoves``),
    /// - status moves whose only effect isn't modeled: confusion, Leech
    ///   Seed, trapping, accuracy and evasion changes, and moves with no
    ///   effect at all (Splash, Protect, weather or hazard moves).
    var isBattleReady: Bool {
        if MoveClassification.chargingMoves.contains(name) { return false }
        if MoveClassification.selfKOMoves.contains(name) { return false }
        if MoveClassification.unsupportedMoves.contains(name) { return false }
        if isDamage { return true }
        if healing > 0 || name == "rest" { return true }
        if Status(ailment: ailment) != .none { return true }
        return !statChanges.isEmpty
    }
}
