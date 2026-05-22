import Foundation

/// Discrete event emitted during a turn for sequential animation playback.
public enum Event: Sendable {
    case used(Side, moveName: String)
    case missed(Side)
    case damaged(Side, amount: Int, effectiveness: Double, crit: Bool)
    case statusApplied(Side, Status)
    case statusTick(Side, Status, amount: Int)
    case statChanged(Side, stat: String, delta: Int)
    case healed(Side, amount: Int)
    case recoil(Side, amount: Int)
    case recharging(Side)
    case wokeUp(Side)
    case fastAsleep(Side)
    case fullyParalyzed(Side)
    case lostFocus(Side)
    case fainted(Side)
    case ended(winner: Side?)
}
