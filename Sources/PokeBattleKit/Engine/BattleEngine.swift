import Foundation

/// Synchronous turn resolver for a one-on-one battle.
///
/// A pure value type with no UI or actor dependencies: it owns a
/// ``BattleState`` and a ``TypeChart``, and the only way to change the state
/// is ``resolveRound(playerMove:opponentMove:using:)``. Because it's a `Sendable`
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
/// full paralysis, secondary-effect chances, sleep length and speed ties are
/// all drawn from the generator passed to
/// ``resolveRound(playerMove:opponentMove:using:)``, so a seeded generator
/// replays a battle exactly; ``resolveRound(playerMove:opponentMove:)`` uses
/// the system random number generator. The AI helpers in this package use
/// the deterministic
/// ``DamageCalculator/estimateDamage(move:attacker:defender:typeChart:)``
/// instead.
public struct BattleEngine: Sendable {
    private let typeChart: TypeChart

    /// The battle after the most recent round. Read it after
    /// ``resolveRound(playerMove:opponentMove:using:)`` to refresh HP bars and
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
    ///    A side that flinched (hit by a flinching move like Fake Out before
    ///    it moved) loses its action.
    /// 2. **End of round.** Burn (1/16 max HP), poison (1/8 max HP) and
    ///    Toxic (1/16 more each round) tick in the same order. If a tick
    ///    causes a faint, the battle ends there.
    ///
    /// Every action starts with a ``Event/used(_:moveName:)`` event, even if
    /// the move then fails (recharging, asleep, fully paralyzed, missed), and
    /// always produces at least one follow-up event. The one exception is a
    /// flinch, which is a lone ``Event/flinched(_:)`` because the move is
    /// never used. When a battle ends the
    /// list finishes with ``Event/fainted(_:)`` followed by
    /// ``Event/ended(winner:)``.
    ///
    /// The moves don't need to belong to the combatants; the engine uses
    /// whatever it's given. PP is not tracked.
    ///
    /// - Parameter generator: The source of every random roll in the round.
    ///   Pass a seeded generator to make battles reproducible.
    /// - Returns: The round's events in playback order, or an empty array if
    ///   the battle has already ended.
    public mutating func resolveRound(
        playerMove: some MoveData,
        opponentMove: some MoveData,
        using generator: inout some RandomNumberGenerator
    ) -> [Event] {
        guard case .selectingMove = state.phase else { return [] }
        var events: [Event] = []
        state.phase = .resolving

        let order = orderedSides(playerMove: playerMove, opponentMove: opponentMove, using: &generator)
        var round = Round()

        for side in order {
            if combatant(side).isFainted || combatant(side.opposite).isFainted { continue }
            switch side {
            case .player:
                performAction(side: .player, move: playerMove, events: &events, round: &round, using: &generator)
            case .opponent:
                performAction(side: .opponent, move: opponentMove, events: &events, round: &round, using: &generator)
            }
            round.acted.insert(side)

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

    /// ``resolveRound(playerMove:opponentMove:using:)`` with the system
    /// random number generator.
    public mutating func resolveRound(
        playerMove: some MoveData,
        opponentMove: some MoveData
    ) -> [Event] {
        var generator = SystemRandomNumberGenerator()
        return resolveRound(playerMove: playerMove, opponentMove: opponentMove, using: &generator)
    }
}

// MARK: - Internal

extension BattleEngine {
    /// Number of hits for a move with PokeAPI's `min_hits`/`max_hits`: 1
    /// for single-hit moves, the fixed count when they're equal, the
    /// 35/35/15/15% distribution for 2-5 hit moves, and uniform otherwise.
    static func rollHits(
        min minHits: Int?,
        max maxHits: Int?,
        using generator: inout some RandomNumberGenerator
    ) -> Int {
        guard let maxHits, maxHits > 1 else { return 1 }
        let minHits = Swift.max(1, minHits ?? maxHits)
        guard minHits < maxHits else { return maxHits }
        if minHits == 2, maxHits == 5 {
            let roll = Double.random(in: 0..<1, using: &generator)
            switch roll {
            case ..<0.35: return 2
            case ..<0.70: return 3
            case ..<0.85: return 4
            default: return 5
            }
        }
        return Int.random(in: minHits...maxHits, using: &generator)
    }

    /// ``rollHits(min:max:using:)`` with the system random number generator.
    static func rollHits(min minHits: Int?, max maxHits: Int?) -> Int {
        var generator = SystemRandomNumberGenerator()
        return rollHits(min: minHits, max: maxHits, using: &generator)
    }
}

// MARK: - Private

private extension BattleEngine {
    /// What's happened so far in the current round.
    struct Round {
        /// Sides that have already taken their action.
        var acted: Set<Side> = []
        /// Sides that took damage; Focus Punch fails if its user is in here.
        var hit: Set<Side> = []
        /// Sides that flinched and lose their action.
        var flinched: Set<Side> = []
    }

    /// Resolves one side's move. The checks run in a fixed order and most of
    /// them end the action early:
    ///
    /// 1. Flinch, if the opponent's flinching move hit first this round.
    /// 2. Recharge turn after a move like Hyper Beam (consumes the turn).
    /// 3. Focus Punch fails if its user was hit earlier this round.
    /// 4. Sleep counts down; the user acts on the turn it wakes up.
    /// 5. Paralysis: 25% chance to be fully paralyzed.
    /// 6. Rest and healing moves resolve without an accuracy check.
    /// 7. First-turn-only moves (Fake Out) fail after the first turn.
    /// 8. Accuracy roll.
    /// 9. Moves that need a poisoned or sleeping target fail without one.
    /// 10. Damage (once per hit), then recharge flag, drain/recoil, flinch,
    ///    ailment, stat changes.
    mutating func performAction(
        side: Side,
        move: some MoveData,
        events: inout [Event],
        round: inout Round,
        using generator: inout some RandomNumberGenerator
    ) {
        // The move as this Pokémon uses it (species rules like Ivy Cudgel's
        // type), so everything below sees the real type and effects.
        let move = move.resolved(for: combatant(side))
        let isFirstTurn = combatant(side).turnsActive == 0
        mutate(side) { $0.turnsActive += 1 }

        if round.flinched.contains(side) {
            events.append(.flinched(side))
            return
        }

        events.append(.used(side, moveName: move.displayName))
        // Used at the end to detect a move that did nothing at all.
        let baselineEventCount = events.count

        if combatant(side).mustRecharge {
            mutate(side) { $0.mustRecharge = false }
            events.append(.recharging(side))
            return
        }

        if move.name == "focus-punch", round.hit.contains(side) {
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

        // Frozen: a 20% chance each turn to thaw out and act.
        if combatant(side).status == .freeze {
            if Double.random(in: 0..<1, using: &generator) < 0.2 {
                mutate(side) { $0.status = .none }
                events.append(.thawed(side))
            } else {
                events.append(.frozenSolid(side))
                return
            }
        }

        if combatant(side).status == .paralysis, Double.random(in: 0..<1, using: &generator) < 0.25 {
            events.append(.fullyParalyzed(side))
            return
        }

        // Rest: heals what a full heal is in the games (the real level-50
        // HP, see `Combatant.baseMaxHP`), then sleep. Replaces any existing
        // status and still puts the user to sleep at full HP.
        if move.name == "rest" {
            let c = combatant(side)
            let healed = min(c.baseMaxHP, c.maxHP - c.currentHP)
            if healed > 0 {
                mutate(side) { $0.currentHP += healed }
                events.append(.healed(side, amount: healed))
            }
            mutate(side) { $0.status = .sleep; $0.sleepTurns = 2; $0.toxicCounter = 0 }
            events.append(.statusApplied(side, .sleep))
            return
        }

        // Healing moves restore `healing`% of the real level-50 HP, capped at
        // missing HP. Nothing else about the move (stat changes etc.) is
        // applied.
        if move.healing > 0 {
            let c = combatant(side)
            let amount = min(c.baseMaxHP * move.healing / 100, c.maxHP - c.currentHP)
            if amount > 0 {
                mutate(side) { $0.currentHP += amount }
                events.append(.healed(side, amount: amount))
            }
            return
        }

        if MoveClassification.firstTurnOnlyMoves.contains(move.name), !isFirstTurn {
            events.append(.failed(side))
            return
        }

        // PokeAPI reports `nil` accuracy for moves that never miss. Accuracy
        // and evasion stat stages are not applied.
        let accuracy = Double(move.accuracy ?? 100) / 100.0
        guard Double.random(in: 0..<1, using: &generator) < accuracy else {
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
        if MoveClassification.requiresSleepingTarget.contains(move.name),
           combatant(side.opposite).status != .sleep {
            events.append(.failed(side))
            return
        }

        var damageDealt = 0
        // Set when the target is immune to the move's type, so a damaging
        // move that "had no effect" can't still inflict its ailment.
        var moveHadNoEffect = false
        let context = TurnContext(
            attackerMovesFirst: !round.acted.contains(side.opposite),
            attackerWasHit: round.hit.contains(side),
            defenderWasHit: round.hit.contains(side.opposite)
        )
        if move.isDamage, move.damageClassKind != .status,
           let movePower = DamageCalculator.power(
               of: move, attacker: combatant(side), defender: combatant(side.opposite),
               context: context, using: &generator
           ) {
            let effectiveness: Double
            var anyCrit = false
            var landed = 0
            switch movePower {
            case .fixed(let amount):
                // Fixed damage ignores stats, STAB and type matchups, except
                // that a type immunity still blocks it (Seismic Toss on a
                // Ghost type).
                let typeMult = typeChart.multiplier(attacking: move.typeName, defenders: combatant(side.opposite).typeNames)
                effectiveness = typeMult == 0 ? 0 : 1
                damageDealt = typeMult == 0 ? 0 : min(amount, combatant(side.opposite).currentHP)
                mutate(side.opposite) { $0.currentHP = max(0, $0.currentHP - damageDealt) }
            case .power(let power):
                // Multi-hit moves roll their hit count up front (2-5 hits
                // land 2, 3, 4 or 5 times with 35/35/15/15% odds) and stop
                // early if the target faints. Each hit rolls its own crit
                // and damage, and escalating moves (Triple Axel) gain power
                // each hit.
                let hits = Self.rollHits(min: move.minHits, max: move.maxHits, using: &generator)
                let escalates = MoveClassification.escalatingMultiHitMoves.contains(move.name)
                var lastEffectiveness = 1.0
                for hit in 1...hits where !combatant(side.opposite).isFainted {
                    let result = DamageCalculator.computeDamage(
                        power: escalates ? power * hit : power,
                        move: move,
                        attacker: combatant(side),
                        defender: combatant(side.opposite),
                        typeChart: typeChart,
                        using: &generator
                    )
                    damageDealt += result.damage
                    lastEffectiveness = result.effectiveness
                    anyCrit = anyCrit || result.crit
                    mutate(side.opposite) { $0.currentHP = max(0, $0.currentHP - result.damage) }
                    if result.effectiveness == 0 { break }
                    landed += 1
                }
                effectiveness = lastEffectiveness
            }
            // The hits are reported as one `.damaged` event with the total
            // (crit if any hit was), followed by `.hitCount`, the way the
            // games show a single "It's super effective!" for the whole move.
            moveHadNoEffect = effectiveness == 0
            events.append(.damaged(side.opposite, amount: damageDealt, effectiveness: effectiveness, crit: anyCrit))
            if damageDealt > 0 { round.hit.insert(side.opposite) }
            if (move.maxHits ?? 1) > 1, landed > 0 {
                events.append(.hitCount(side.opposite, count: landed))
            }
            // A Fire-type hit thaws a frozen target.
            if damageDealt > 0, move.typeName == "fire", combatant(side.opposite).status == .freeze {
                mutate(side.opposite) { $0.status = .none }
                events.append(.thawed(side.opposite))
            }
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

        // Negative `healing` on an attack is an HP cost of that share of the
        // user's real max HP (Struggle's quarter).
        if move.healing < 0, move.isDamage, damageDealt > 0 {
            let cost = max(1, combatant(side).baseMaxHP * -move.healing / 100)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - cost) }
            events.append(.recoil(side, amount: cost))
        }

        if move.drain < 0, damageDealt > 0 {
            let recoilDmg = max(1, damageDealt * abs(move.drain) / 100)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - recoilDmg) }
            events.append(.recoil(side, amount: recoilDmg))
        }

        // A flinch only matters if the target hasn't acted yet this round.
        if move.flinchChance > 0, damageDealt > 0, !round.acted.contains(side.opposite),
           Double.random(in: 0..<1, using: &generator) < Double(move.flinchChance) / 100.0 {
            round.flinched.insert(side.opposite)
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
               combatant(target).status == .none, Double.random(in: 0..<1, using: &generator) < chance {
                mutate(target) {
                    $0.status = ailment
                    if ailment == .sleep { $0.sleepTurns = Int.random(in: 1...3, using: &generator) }
                    $0.toxicCounter = move.inflictsBadPoison ? 1 : 0
                }
                events.append(.statusApplied(target, ailment))
            }
        }

        // Stat changes. Status moves (Swords Dance, Growl) always apply them;
        // damaging moves apply them with `effectChance`% probability, or always
        // when PokeAPI gives no chance. Self-debuffing moves (Overheat, Close
        // Combat) always pay their drawback. A damaging move that had no
        // effect changes nothing. Who each change applies to comes from
        // ``MoveData/statChanges``; accuracy and evasion are skipped.
        let secondaryGate: Double = {
            guard move.damageClassKind != .status, let chance = move.effectChance else { return 1.0 }
            return Double(chance) / 100.0
        }()
        let triggersStatChange = !moveHadNoEffect
            && (move.hasSelfDebuff || Double.random(in: 0..<1, using: &generator) < secondaryGate)
        if triggersStatChange {
            for change in move.statChanges {
                let target: Side = change.target == .user ? side : side.opposite
                mutate(target) { $0.applyStage(change.stat, delta: change.delta) }
                events.append(.statChanged(target, stat: change.stat, delta: change.delta))
            }
        }

        // Nothing happened (e.g. a status move into an already-statused
        // target): emit the "no effect" event so the UI always has a result
        // to show after `.used`.
        if events.count == baselineEventCount {
            events.append(.damaged(side.opposite, amount: 0, effectiveness: 0, crit: false))
        }
    }

    /// End-of-round residual damage, as fractions of the real level-50 HP
    /// (`Combatant.baseMaxHP`). Toxic deals `toxicCounter`/16
    /// and then escalates, up to 15/16. Never brings HP below 0.
    mutating func applyStatusTick(side: Side, events: inout [Event]) {
        let c = combatant(side)
        guard !c.isFainted else { return }
        switch c.status {
        case .burn:
            let damage = max(1, c.baseMaxHP / 16)
            mutate(side) { $0.currentHP = max(0, $0.currentHP - damage) }
            events.append(.statusTick(side, .burn, amount: damage))
        case .poison:
            let damage = c.isBadlyPoisoned
                ? max(1, c.baseMaxHP * c.toxicCounter / 16)
                : max(1, c.baseMaxHP / 8)
            mutate(side) {
                $0.currentHP = max(0, $0.currentHP - damage)
                if $0.toxicCounter > 0 { $0.toxicCounter = min(15, $0.toxicCounter + 1) }
            }
            events.append(.statusTick(side, .poison, amount: damage))
        case .paralysis, .sleep, .freeze, .none:
            break
        }
    }

    /// Turn order: priority bracket first, then effective speed, then a coin
    /// flip on an exact tie.
    func orderedSides(
        playerMove: some MoveData,
        opponentMove: some MoveData,
        using generator: inout some RandomNumberGenerator
    ) -> [Side] {
        let playerKey = (playerMove.priority, state.player.effectiveSpeed)
        let opponentKey = (opponentMove.priority, state.opponent.effectiveSpeed)
        if playerKey.0 != opponentKey.0 {
            return playerKey.0 > opponentKey.0 ? [.player, .opponent] : [.opponent, .player]
        }
        if playerKey.1 != opponentKey.1 {
            return playerKey.1 > opponentKey.1 ? [.player, .opponent] : [.opponent, .player]
        }
        return Bool.random(using: &generator) ? [.player, .opponent] : [.opponent, .player]
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
