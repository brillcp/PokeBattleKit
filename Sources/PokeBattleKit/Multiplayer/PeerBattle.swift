import Foundation

/// One device's half of a battle between two devices, with no networking:
/// feed it this device's moves (``commit(_:)``) and the peer's turn
/// messages (``receive(_:)``), and carry out the ``Step``s it returns.
///
/// The host is authoritative, in lockstep:
/// 1. Each side commits a move for the next turn number, which sends the
///    peer a ``TurnMessage/moveCommitted(moveName:turnNumber:)``.
/// 2. As soon as the host holds both moves for the same turn, it resolves
///    the round with its ``BattleEngine``.
/// 3. The host sends ``TurnMessage/roundResolved(events:turnNumber:)``,
///    and both devices play the identical events (the guest mirrored, see
///    ``Event/mirrored``), so damage rolls and crits can't diverge.
///
/// Turn numbers let each side ignore stale or out-of-order messages. Both
/// devices see the battle from their own side: each one's own combatant is
/// ``Side/player``.
///
/// ```swift
/// var battle = PeerBattle(role: .host, state: state, typeChart: chart, peerMoves: theirMoves)
/// for step in battle.commit(myMove) {
///     switch step {
///     case .send(let message): transport.send(.turn(message))
///     case .play(let events): await animate(events)
///     case .peerCommitted, .ended: break
///     }
/// }
/// ```
public struct PeerBattle: Sendable {
    public enum Role: Sendable {
        /// Runs the engine. Decide which device hosts when they connect.
        case host
        /// Plays the host's resolved rounds.
        case guest
    }

    /// Something for the device to do, in order.
    public enum Step: Sendable {
        /// Send this to the peer.
        case send(TurnMessage)
        /// Play these events back, already from this device's perspective.
        case play([Event])
        /// The peer committed its move first; this device hasn't yet (for a
        /// "choose your move" prompt).
        case peerCommitted
        /// The host reported the battle over, from this device's
        /// perspective (`nil` for a draw). The played events already ended
        /// with ``Event/ended(winner:)``; this confirms it.
        case ended(winner: Side?)
    }

    public let role: Role
    /// The latest turn this device committed a move for.
    public private(set) var turnNumber = 0
    /// This device's move for ``turnNumber``, until the round resolves.
    /// Commit nothing else while it's set.
    public private(set) var committedMove: Move?

    /// Host only.
    private var engine: BattleEngine?
    private let peerMoves: [Move]
    private var peerMoveName: String?

    /// - Parameters:
    ///   - state: The battle from this device's side (its own combatant is
    ///     the ``BattleState/player``).
    ///   - typeChart: Used by the host's engine.
    ///   - peerMoves: The peer's loadout, from its challenge. The host only
    ///     accepts the peer's moves from this list.
    public init(role: Role, state: BattleState, typeChart: TypeChart, peerMoves: [Move]) {
        self.role = role
        self.peerMoves = peerMoves
        self.engine = role == .host ? BattleEngine(state: state, typeChart: typeChart) : nil
    }

    /// The host's battle state after the last round, to re-sync a display
    /// that reduced the events itself; `nil` on the guest.
    public var hostState: BattleState? { engine?.state }

    /// Commit this device's move for the next turn. Returns nothing if a
    /// move is already committed.
    public mutating func commit(_ move: Move) -> [Step] {
        guard committedMove == nil else { return [] }
        turnNumber += 1
        committedMove = move
        return [.send(.moveCommitted(moveName: move.name, turnNumber: turnNumber))] + resolveIfReady()
    }

    /// Handle a turn message from the peer. Stale, out-of-order and
    /// wrong-role messages return nothing.
    public mutating func receive(_ message: TurnMessage) -> [Step] {
        switch message {
        case .moveCommitted(let name, let turn):
            // The peer's move for the turn this device committed, or for the
            // next one when the peer committed first.
            guard turn == (committedMove == nil ? turnNumber + 1 : turnNumber) else { return [] }
            let prompt: [Step] = committedMove == nil ? [.peerCommitted] : []
            guard role == .host else { return prompt }
            peerMoveName = name
            return prompt + resolveIfReady()
        case .roundResolved(let events, let turn):
            guard role == .guest, committedMove != nil, turn == turnNumber else { return [] }
            committedMove = nil
            return [.play(events.map(\.mirrored))]
        case .battleEnded(let winner):
            guard role == .guest else { return [] }
            return [.ended(winner: winner?.opposite)]
        }
    }
}

// MARK: - Private

private extension PeerBattle {
    /// Host: resolves the round once both moves for the turn are in.
    /// Messages go first, so both devices play the round together.
    mutating func resolveIfReady() -> [Step] {
        guard role == .host,
              let ownMove = committedMove,
              let name = peerMoveName,
              let peerMove = peerMoves.first(where: { $0.name == name }),
              var engine
        else { return [] }
        let events = engine.resolveRound(playerMove: ownMove, opponentMove: peerMove)
        self.engine = engine
        committedMove = nil
        peerMoveName = nil
        var steps: [Step] = [.send(.roundResolved(events: events, turnNumber: turnNumber))]
        if case .ended(let winner)? = events.last {
            steps.append(.send(.battleEnded(winner: winner)))
        }
        steps.append(.play(events))
        return steps
    }
}
