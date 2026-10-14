import Foundation

/// Discrete event emitted during a turn for sequential animation playback.
///
/// ``BattleEngine/resolveRound(playerMove:opponentMove:)`` returns the
/// round's events in the order they happened. The engine has already applied
/// all of them to its ``BattleEngine/state`` by the time you receive them, so
/// a UI typically walks the list one event at a time, animating each (HP bar
/// drain, message text, faint) and tracking displayed HP itself, then syncs
/// to the final state. The `Side` in each case is the combatant the event
/// happens *to*: for ``damaged(_:amount:effectiveness:crit:)`` that's the
/// target, for ``used(_:moveName:)`` the user.
///
/// `Codable` with a flat `"type"` discriminator (e.g.
/// `{"type":"damaged","side":"opponent","amount":42,...}`) so event logs can
/// be stored or sent to another process.
public enum Event: Sendable, Codable {
    /// A side starts its action. Always the first event of an action, even
    /// when the move then fails.
    case used(Side, moveName: String)
    case missed(Side)
    /// HP lost by `side`. `effectiveness` is the raw, uncapped type
    /// multiplier (use it for "super effective" messages). An `amount` and
    /// `effectiveness` of 0 means the move had no effect.
    case damaged(Side, amount: Int, effectiveness: Double, crit: Bool)
    case statusApplied(Side, Status)
    /// End-of-round burn or poison damage.
    case statusTick(Side, Status, amount: Int)
    /// A stat stage change; `stat` is the PokeAPI stat name and `delta` the
    /// requested change, which may have been clamped at +/-6.
    case statChanged(Side, stat: String, delta: Int)
    case healed(Side, amount: Int)
    /// Damage the attacker takes from its own move (negative drain).
    case recoil(Side, amount: Int)
    /// The side spent its action recharging after a move like Hyper Beam.
    case recharging(Side)
    case wokeUp(Side)
    case fastAsleep(Side)
    case fullyParalyzed(Side)
    /// Focus Punch failed because its user was hit first.
    case lostFocus(Side)
    /// Emitted right before ``ended(winner:)``.
    case fainted(Side)
    /// The battle is over; always the last event. The engine always reports
    /// a winner; `nil` is available to hosts that model draws or forfeits.
    case ended(winner: Side?)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, side, moveName, amount, effectiveness, crit, status, stat, delta, winner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "used":
            self = .used(try c.decode(Side.self, forKey: .side), moveName: try c.decode(String.self, forKey: .moveName))
        case "missed":
            self = .missed(try c.decode(Side.self, forKey: .side))
        case "damaged":
            self = .damaged(
                try c.decode(Side.self, forKey: .side),
                amount: try c.decode(Int.self, forKey: .amount),
                effectiveness: try c.decode(Double.self, forKey: .effectiveness),
                crit: try c.decode(Bool.self, forKey: .crit)
            )
        case "statusApplied":
            self = .statusApplied(try c.decode(Side.self, forKey: .side), try c.decode(Status.self, forKey: .status))
        case "statusTick":
            self = .statusTick(
                try c.decode(Side.self, forKey: .side),
                try c.decode(Status.self, forKey: .status),
                amount: try c.decode(Int.self, forKey: .amount)
            )
        case "statChanged":
            self = .statChanged(
                try c.decode(Side.self, forKey: .side),
                stat: try c.decode(String.self, forKey: .stat),
                delta: try c.decode(Int.self, forKey: .delta)
            )
        case "healed":
            self = .healed(try c.decode(Side.self, forKey: .side), amount: try c.decode(Int.self, forKey: .amount))
        case "recoil":
            self = .recoil(try c.decode(Side.self, forKey: .side), amount: try c.decode(Int.self, forKey: .amount))
        case "recharging":
            self = .recharging(try c.decode(Side.self, forKey: .side))
        case "wokeUp":
            self = .wokeUp(try c.decode(Side.self, forKey: .side))
        case "fastAsleep":
            self = .fastAsleep(try c.decode(Side.self, forKey: .side))
        case "fullyParalyzed":
            self = .fullyParalyzed(try c.decode(Side.self, forKey: .side))
        case "lostFocus":
            self = .lostFocus(try c.decode(Side.self, forKey: .side))
        case "fainted":
            self = .fainted(try c.decode(Side.self, forKey: .side))
        case "ended":
            self = .ended(winner: try c.decodeIfPresent(Side.self, forKey: .winner))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown event type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .used(let side, let moveName):
            try c.encode("used", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(moveName, forKey: .moveName)
        case .missed(let side):
            try c.encode("missed", forKey: .type)
            try c.encode(side, forKey: .side)
        case .damaged(let side, let amount, let effectiveness, let crit):
            try c.encode("damaged", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(amount, forKey: .amount)
            try c.encode(effectiveness, forKey: .effectiveness)
            try c.encode(crit, forKey: .crit)
        case .statusApplied(let side, let status):
            try c.encode("statusApplied", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(status, forKey: .status)
        case .statusTick(let side, let status, let amount):
            try c.encode("statusTick", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(status, forKey: .status)
            try c.encode(amount, forKey: .amount)
        case .statChanged(let side, let stat, let delta):
            try c.encode("statChanged", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(stat, forKey: .stat)
            try c.encode(delta, forKey: .delta)
        case .healed(let side, let amount):
            try c.encode("healed", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(amount, forKey: .amount)
        case .recoil(let side, let amount):
            try c.encode("recoil", forKey: .type)
            try c.encode(side, forKey: .side)
            try c.encode(amount, forKey: .amount)
        case .recharging(let side):
            try c.encode("recharging", forKey: .type)
            try c.encode(side, forKey: .side)
        case .wokeUp(let side):
            try c.encode("wokeUp", forKey: .type)
            try c.encode(side, forKey: .side)
        case .fastAsleep(let side):
            try c.encode("fastAsleep", forKey: .type)
            try c.encode(side, forKey: .side)
        case .fullyParalyzed(let side):
            try c.encode("fullyParalyzed", forKey: .type)
            try c.encode(side, forKey: .side)
        case .lostFocus(let side):
            try c.encode("lostFocus", forKey: .type)
            try c.encode(side, forKey: .side)
        case .fainted(let side):
            try c.encode("fainted", forKey: .type)
            try c.encode(side, forKey: .side)
        case .ended(let winner):
            try c.encode("ended", forKey: .type)
            try c.encodeIfPresent(winner, forKey: .winner)
        }
    }
}
