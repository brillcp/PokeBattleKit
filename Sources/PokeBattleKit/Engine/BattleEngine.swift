import Foundation

/// Synchronous turn resolver for a one-on-one battle.
///
/// A pure value type with no UI or actor dependencies: it owns a
/// ``BattleState`` and a ``TypeChart``, and the only way to change the state
/// is ``resolveRound(playerMove:opponentMove:)``. Because it's a `Sendable`
/// struct, copying the engine (or its ``state``) gives an independent
/// snapshot, so a host can hand a copy to a background AI or keep one for
/// undo without any locking.
///
/// Typical use:
///
/// ```swift
/// var engine = BattleEngine(state: BattleState(player: me, opponent: foe),
///                           typeChart: PokeBattleKit.typeChart)
/// let events = engine.resolveRound(playerMove: myPick, opponentMove: aiPick)
/// for event in events { await animate(event) }   // play back in order
/// let hp = engine.state.player.currentHP          // final state after the round
/// ```
///
/// The engine is *not* deterministic: accuracy checks, crits, damage rolls,
/// full paralysis, secondary-effect chances, sleep length and speed ties all
/// use the system random number generator. The AI helpers in this package
/// use the deterministic
/// ``DamageCalculator/estimateDamage(move:attacker:defender:typeChart:superEffectiveCap:)``
/// instead.
public struct BattleEngine: Sendable {
    private let typeChart: TypeChart

    /// The battle after the most recent round. Read it after
    /// ``resolveRound(playerMove:opponentMove:)`` to refresh HP bars and
    /// status badges; the returned events describe how it got there.
    public private(set) var state: BattleState

    public init(state: BattleState, typeChart: TypeChart) {
        self.state = state
        self.typeChart = typeChart
    }

    /// Resolves one round in which both sides act, and returns what happened
    /// as an ordered list of ``Event`` values for the UI to play back.
    ///
    /// A round runs in two parts:
    /// 1. **Actions.** Both sides act in turn order: higher move `priority`
    ///    goes first; on equal priority the higher
    ///    ``Combatant/effectiveSpeed`` goes first (speed stat stages apply,
    ///    then paralysis halves it); an exact tie is a coin flip.
    ///    The battle ends immediately when anyone faints after an action, so
    ///    a KO'd defender never gets its turn.
    /// 2. **End of round.** Burn (1/16 max HP) and poison (1/8 max HP) tick
    ///    in the same order. If a tick causes a faint, the battle ends there.
    ///
    /// Every action starts with a ``Event/used(_:moveName:)`` event, even if
    /// the move then fails (recharging, asleep, fully paralyzed, missed), and
    /// always produces at least one follow-up event. When a battle ends the
    /// list finishes with ``Event/fainted(_:)`` followed by
    /// ``Event/ended(winner:)``.
    ///
    /// The moves don't need to belong to the combatants; the engine uses
    /// whatever it's given. PP is not tracked.
    ///
    /// - Returns: The round's events in playback order, or an empty array if
    ///   the battle has already ended.
    public mutating func resolveRound(
        playerMove: some MoveData,
        opponentMove: some MoveData
    ) -> [Event] {
        guard case .selectingMove = state.phase else { return [] }
        var events: [Event] = []
        state.phase = .resolving

        let order = orderedSides(playerMove: playerMove, opponentMove: opponentMove)
        // Sides that took damage earlier in this round; Focus Punch fails
        // if its user is in here.
        var hitThisRound: Set<Side> = []

        for side in order {
            if combatant(side).isFainted || combatant(side.opposite).isFainted { continue }
            switch side {
            case .player:
                performAction(side: .player, move: playerMove, events: &events, hitThisRound: &hitThisRound)
            case .opponent:
                performAction(side: .opponent, move: opponentMove, events: &events, hitThisRound: &hitThisRound)
            }

            if let result = checkFaint(after: side, events: &events) {
                return result
            }
        }

        // End-of-round residual damage. The first side to faint here loses;
        // the other side doesn't tick.
        for side in order {
            applyStatusTick(side: side, events: &events)
            if combatant(side).isFainted {
                events.append(.fainted(side))
                state.phase = .ended(winner: side.opposite)
                events.append(.ended(winner: side.opposite))
                return events
            }
        }

        state.phase = .selectingMove
        return events
    }
}

// MARK: - Private

private extension BattleEngine {
    /// Resolves one side's move. The checks run in a fixed order and most of
    /// them end the action early:
    ///
    /// 1. Recharge turn after a move like Hyper Beam (consumes the turn).
    /// 2. Focus Punch fails if its user was hit earlier this round.
    /// 3. Sleep counts down; the user acts on the turn it wakes up.
    /// 4. Paralysis: 25% chance to be fully paralyzed.
    /// 5. Rest and healing moves resolve without an accuracy check.
    /// 6. Accuracy roll.
    /// 7. Damage, then recharge flag, drain/recoil, ailment, stat changes.
    mutating func performAction(
        side: Side,
        move: some MoveData,
        events: inout [Event],
        hitThisRound: inout Set<Side>
    ) {
        events.append(.used(side, moveName: move.displayName))
        // Used at the end to detect a move that did nothing at all.
        let baselineEventCount = events.count

        if combatant(side).mustRecharge {
            mutate(side) { $0.mustRecharge = false }
            events.append(.recharging(side))
            return
        }

        if move.name == "focus-punch", hitThisRound.contains(side) {
            events.append(.lostFocus(side))
            return
        }

        // A counter of N skips exactly N turns: while it's above 0 the turn is
        // lost and it counts down; the next attempt wakes up and acts. Sleep
        // moves roll 1-3 turns, and Rest's counter of 2 skips two turns.
        if combatant(side).status == .sleep {
            if combatant(side).sleepTurns > 0 {
                mutate(side) { $0.sleepTurns -= 1 }
                events.append(.fastAsleep(side))
                return
            }
            mutate(side) { $0.status = .none }
            events.append(.wokeUp(side))
        }

        if combatant(side).status == .paralysis, Double.random(in: 0..<1) < 0.25 {
            events.append(.fullyParalyzed(side))
            return
        }

        // Rest: full heal, then sleep. Replaces any existing status and still
        // puts the user to sleep at full HP.
        if move.name == "rest" {
            let c = combatant(side)
            let healed = c.maxHP - c.currentHP
            if healed > 0 {
                mutate(side) { $0.currentHP = $0.maxHP }
                events.append(.healed(side, amount: healed))
            }
            mutate(side) { $0.status = .sleep; $0.sleepTurns = 2 }
            events.append(.statusApplied(side, .sleep))
            return
        }

        // Healing moves restore `healing`% of max HP, capped at missing HP.
        // Nothing else about the move (stat changes etc.) is applied.
        if move.healing > 0 {
            let c = combatant(side)
            let amount = min(c.maxHP * move.healing / 100, c.maxHP - c.currentHP)
            if amount > 0 {
                mutate(side) { $0.currentHP += amount }
                events.append(.healed(side, amount: amount))
            }
            return
        }

        // PokeAPI reports `nil` accuracy for moves that never miss. Accuracy
        // and evasion stat stages are not applied.
        let accuracy = Double(move.accuracy ?? 100) / 100.0
        guard Double.random(in: 0..<1) < accuracy else {
            events.append(.missed(side))
            return
        }

        // A zero-damage, zero-effectiveness `.damaged` event is the engine's
        // "it had no effect" signal to the UI.
        if MoveClassification.requiresPoisonedTarget.contains(move.name),
           combatant(side.opposite).status != .poison {
            events.append(.damaged(side.opposite, amount: 0, effectiveness: 0, crit: false))
            return
        }

        var damageDealt = 0
        // Set when the target is immune to the move's type, so a damaging
        // move that "had no effect" can't still inflict its ailment.
        var moveHadNoEffect = false
        if let power = move.power, power > 0, move.damageClassKind != .status {
            let (damage, effectiveness, crit) = DamageCalculator.computeDamage(
                power: power,
                move: move,
                attacker: combatant(side),
                defender: combatant(side.opposite),
                typeChart: typeChart
            )
            damageDealt = damage
            moveHadNoEffect = effectiveness == 0
            mutate(side.opposite) { $0.currentHP = max(0, $0.currentHP - damage) }
            events.append(.damaged(side.opposite, amount: damage, effectiveness: effectiveness, crit: crit))
            if damage > 0 { hitThisRound.insert(side.opposite) }
        }

        // Only reached when the move hit, so a missed Hyper Beam doesn't
        // cost a recharge turn.
        if move.isRechargeMove { mutate(side) { $0.mustRecharge = true } }

        // PokeAPI's `drain` is a signed percentage of damage dealt: positive
        // heals the user (Giga Drain), negative is recoil (Double-Edge).
        // Either way at least 1 HP moves when any damage was dealt.
        if move.drain > 0, damageDealt > 0 {
            let healed = max(1, damageDealt * move.drain / 100)
            mutate(side) { $0.currentHP = min($0.maxHP, $0.currentHP + healed) }
            events.append(.healed(side, amount: healed))
        }

        if move.drain < 0, damageDealt > 0 {
            let recoilDmg = max(1, damageDealt * abs(move.drain) / 100)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - recoilDmg) }
            events.append(.recoil(side, amount: recoilDmg))
        }

        // Ailments always target the opponent and only land on a healthy
        // target (no stacking or overwriting). They're blocked when:
        // - a damaging move had no effect (Body Slam into a Ghost type),
        // - a status move that respects type matchups hits an immune type
        //   (Thunder Wave into a Ground type), or
        // - the target's type can't have that status (Fire can't be burned).
        // PokeAPI reports an ailment chance of 0 for most status moves
        // (Thunder Wave), which here means "always"; a damaging move with a
        // chance of 0 never inflicts its ailment.
        let ailment = Status(ailment: move.ailment)
        if ailment != .none, move.ailmentChance > 0 || move.damageClassKind == .status {
            let chance = move.ailmentChance > 0 ? Double(move.ailmentChance) / 100.0 : 1.0
            let target: Side = side.opposite
            let targetTypes = combatant(target).typeNames
            let blockedByMoveType = moveHadNoEffect
                || (MoveClassification.respectsTypeImmunity.contains(move.name)
                    && typeChart.multiplier(attacking: move.typeName, defenders: targetTypes) == 0)
            if !blockedByMoveType, !ailment.isImmune(typeNames: targetTypes),
               combatant(target).status == .none, Double.random(in: 0..<1) < chance {
                mutate(target) {
                    $0.status = ailment
                    if ailment == .sleep { $0.sleepTurns = Int.random(in: 1...3) }
                }
                events.append(.statusApplied(target, ailment))
            }
        }

        // Stat changes. Status moves (Swords Dance, Growl) always apply them;
        // damaging moves apply them with `effectChance`% probability, or always
        // when PokeAPI gives no chance. Self-debuffing moves (Overheat, Close
        // Combat) always pay their drawback.
        let secondaryGate: Double = {
            guard move.damageClassKind != .status, let chance = move.effectChance else { return 1.0 }
            return Double(chance) / 100.0
        }()
        let triggersStatChange = move.hasSelfDebuff || Double.random(in: 0..<1) < secondaryGate
        if triggersStatChange {
            // `MoveData` carries no target field, so the target is inferred:
            // self-debuff moves and moves mixing raises with drops (Shell
            // Smash) change only the user; otherwise raises go to the user
            // and drops go to the opponent.
            let allSelfTarget = move.hasSelfDebuff
                || (move.statChangeDeltas.contains { $0 > 0 } && move.statChangeDeltas.contains { $0 < 0 })
            for (index, statName) in move.statChangeNames.enumerated() where index < move.statChangeDeltas.count {
                let delta = move.statChangeDeltas[index]
                guard delta != 0 else { continue }
                let target: Side = allSelfTarget ? side : (delta < 0 ? side.opposite : side)
                mutate(target) { $0.applyStage(statName, delta: delta) }
                events.append(.statChanged(target, stat: statName, delta: delta))
            }
        }

        // Nothing happened (e.g. a status move into an already-statused
        // target): emit the "no effect" event so the UI always has a result
        // to show after `.used`.
        if events.count == baselineEventCount {
            events.append(.damaged(side.opposite, amount: 0, effectiveness: 0, crit: false))
        }
    }

    /// End-of-round residual damage. `bad-poison` is mapped to regular
    /// poison, so Toxic doesn't escalate. Never brings HP below 0.
    mutating func applyStatusTick(side: Side, events: inout [Event]) {
        let c = combatant(side)
        guard !c.isFainted else { return }
        switch c.status {
        case .burn:
            let damage = max(1, c.maxHP / 16)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - damage) }
            events.append(.statusTick(side, .burn, amount: damage))
        case .poison:
            let damage = max(1, c.maxHP / 8)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - damage) }
            events.append(.statusTick(side, .poison, amount: damage))
        case .paralysis, .sleep, .none:
            break
        }
    }

    /// Turn order: priority bracket first, then effective speed, then a coin
    /// flip on an exact tie.
    func orderedSides(playerMove: some MoveData, opponentMove: some MoveData) -> [Side] {
        let playerKey = (playerMove.priority, state.player.effectiveSpeed)
        let opponentKey = (opponentMove.priority, state.opponent.effectiveSpeed)
        if playerKey.0 != opponentKey.0 {
            return playerKey.0 > opponentKey.0 ? [.player, .opponent] : [.opponent, .player]
        }
        if playerKey.1 != opponentKey.1 {
            return playerKey.1 > opponentKey.1 ? [.player, .opponent] : [.opponent, .player]
        }
        return Bool.random() ? [.player, .opponent] : [.opponent, .player]
    }

    func combatant(_ side: Side) -> Combatant {
        side == .player ? state.player : state.opponent
    }

    /// Ends the battle if either side fainted during `side`'s action and
    /// returns the finished event list. The acting side is checked first, so
    /// if a move KOs the target but the user also faints from recoil, the
    /// user loses.
    mutating func checkFaint(after side: Side, events: inout [Event]) -> [Event]? {
        if combatant(side).isFainted {
            events.append(.fainted(side))
            state.phase = .ended(winner: side.opposite)
            events.append(.ended(winner: side.opposite))
            return events
        }
        if combatant(side.opposite).isFainted {
            events.append(.fainted(side.opposite))
            state.phase = .ended(winner: side)
            events.append(.ended(winner: side))
            return events
        }
        return nil
    }

    mutating func mutate(_ side: Side, _ body: (inout Combatant) -> Void) {
        if side == .player {
            body(&state.player)
        } else {
            body(&state.opponent)
        }
    }
}
