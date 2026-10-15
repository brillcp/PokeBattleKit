import Foundation

/// Move-evaluation primitive used by both move-pick and loadout-pick
/// strategies. Higher score = better for the fighter.
///
/// Everything is scored in one unit, *HP of damage*, so attacks and
/// support moves compete on the same scale:
/// - An attack is worth the damage it's expected to deal (capped at the
///   target's remaining HP), plus a bonus for a likely KO.
/// - A support move is worth the damage it gains or prevents over the next
///   few actions. A Swords Dance is worth the extra damage of the attacks
///   after it, a burn the damage the opponent won't deal, a heal the extra
///   actions it buys. To work that out the scorer builds a short
///   ``Outlook`` of the fight: each side's best expected damage per action,
///   who moves first, and how many actions each side gets before fainting.
///
/// The fighter's and opponent's ``Combatant/moves`` are used for those
/// damage figures. A combatant without moves (for example while choosing a
/// loadout) is assumed to have an 80-power same-type attack in its better
/// attacking stat.
///
/// Scores are deterministic: damage comes from
/// ``DamageCalculator/estimateDamage(move:attacker:defender:typeChart:)``.
/// The randomness in move choice lives in
/// ``MoveStrategy/heuristicPick(attacker:defender:moves:typeChart:recentMoves:difficulty:)``.
public enum MoveScoring {

    /// Score of `move` for `fighter` against `opponent` in the current
    /// state, without in-battle history. Used for ranking loadout
    /// candidates and as the base of
    /// ``inBattleScore(move:attacker:defender:typeChart:recentMoves:)``.
    ///
    /// Damaging moves:
    /// - expected damage (top roll x 0.925 average roll x accuracy), capped
    ///   at the target's remaining HP so overkill counts for nothing,
    /// - +``Weights/koBonus`` x the chance it KOs (accounting for accuracy
    ///   and the damage roll), or +``Weights/twoHitKOBonus`` when two hits
    ///   would KO,
    /// - the value of its secondary effects (ailment, stat changes, flinch,
    ///   drain, recoil) weighted by their chance, which is how Close
    ///   Combat's Defense drops or Flame Charge's Speed boost are priced,
    /// - minus the action lost to a recharge (Hyper Beam) when it doesn't KO.
    ///
    /// Support moves are worth the HP-of-damage they gain or prevent (see
    /// the type docs), times their accuracy. One that would do nothing (a
    /// heal at full HP, a status on an already-statused target, a boost at
    /// +6) scores 0.
    ///
    /// Moves that can't work at all score ``Weights/disallowed``: a move
    /// the target's type is immune to, Thunder Wave into a Ground type,
    /// Venom Drench or Dream Eater without the right target status, or Fake
    /// Out after the first turn.
    public static func score(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        let move = move.resolved(for: fighter)
        guard isUsable(move, attacker: fighter, defender: opponent, typeChart: typeChart) else {
            return Weights.disallowed
        }
        let outlook = Outlook(fighter: fighter, opponent: opponent, typeChart: typeChart)
        if move.isDamage, move.damageClassKind != .status {
            return damageScore(move: move, fighter: fighter, opponent: opponent, outlook: outlook, typeChart: typeChart)
        }
        let accuracy = Double(move.accuracy ?? 100) / 100
        return effectValue(of: move, chance: 1, fighter: fighter, opponent: opponent, outlook: outlook, typeChart: typeChart) * accuracy
    }

    /// In-battle score: ``score(move:fighter:opponent:typeChart:)`` adjusted
    /// for the turn order threat and recent history. `recentMoves` is the
    /// rolling window of move names the AI has picked on prior turns
    /// (newest last).
    ///
    /// Adjustments:
    /// - **Speed threat.** If the defender moves first and can KO the
    ///   attacker this turn, any move without priority is only worth what
    ///   it's worth if the defender misses, so its score is scaled by the
    ///   chance of surviving. Priority moves aren't, so a nearly-fainted AI
    ///   gets its last hit in with Quick Attack or Bullet Punch.
    /// - **Variety.** Repeating the same move costs a mild
    ///   ``Weights/repeatPenalty`` per turn of the current streak, which
    ///   only changes the pick between near-equal moves; a clearly best
    ///   move still gets used every turn.
    /// - **Back-to-back recharge.** A recharge move scores only 20% when any
    ///   recharge move is in the window, to avoid chaining lost turns.
    /// - **Redundant status.** Pure status moves lose
    ///   ``Weights/redundantStatusPenalty`` when the defender already has a
    ///   status, so they sort below any useful move. Damaging moves with a
    ///   secondary ailment aren't penalized.
    public static func inBattleScore(
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String]
    ) -> Double {
        var score = Self.score(move: move, fighter: attacker, opponent: defender, typeChart: typeChart)
        guard score > Weights.disallowed else { return score }

        let outlook = Outlook(fighter: attacker, opponent: defender, typeChart: typeChart)
        if outlook.isThreatened, !outlook.weMoveFirst, move.priority <= 0, score > 0 {
            score *= 1 - outlook.theirKOChance * (outlook.speedTie ? 0.5 : 1)
        }

        // Tempo: each non-attacking move in a row is worth half the last.
        // A support move's value assumes its effect sticks, but the
        // opponent can undo it (Swords Dance against Charm), and two
        // support-minded AIs would otherwise trade effects forever. Setting
        // up stays worthwhile; looping can't.
        if !move.isDamage, score > 0 {
            let supportStreak = recentMoves.reversed().prefix { name in
                attacker.moves.first { $0.name == name }.map { !$0.isDamage } ?? false
            }.count
            score *= pow(Weights.supportStreakDecay, Double(supportStreak))
        }

        let streak = recentMoves.suffix(4).reversed().prefix(while: { $0 == move.name }).count
        score -= Double(streak) * Weights.repeatPenalty

        if move.isRechargeMove,
           recentMoves.contains(where: { MoveClassification.rechargeMoves.contains($0) }) {
            score *= Weights.rechargeRecentMult
        }

        if !move.isDamage, defender.status != .none, Status(ailment: move.ailment) != .none {
            score -= Weights.redundantStatusPenalty
        }
        return score
    }

    /// Whether `move` can have any effect: false for moves the defender's
    /// type is immune to, Thunder Wave into a Ground type, Venom Drench and
    /// Dream Eater without a poisoned or sleeping target, and Fake Out after
    /// the attacker's first turn.
    public static func isUsable(
        _ move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Bool {
        let move = move.resolved(for: attacker)
        if MoveClassification.requiresPoisonedTarget.contains(move.name), defender.status != .poison { return false }
        if MoveClassification.requiresSleepingTarget.contains(move.name), defender.status != .sleep { return false }
        if MoveClassification.firstTurnOnlyMoves.contains(move.name), attacker.turnsActive > 0 { return false }
        let checksType = (move.isDamage && move.damageClassKind != .status)
            || MoveClassification.respectsTypeImmunity.contains(move.name)
        if checksType, typeChart.multiplier(attacking: move.typeName, defenders: defender.typeNames) == 0 {
            return false
        }
        return true
    }

    /// Expected damage of one use of `move`: the top roll times the
    /// average roll (0.925) times accuracy. 0 if it can't deal damage.
    public static func expectedDamage(
        _ move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        guard isUsable(move, attacker: attacker, defender: defender, typeChart: typeChart) else { return 0 }
        let estimate = DamageCalculator.estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: typeChart)
        return Double(estimate) * Weights.averageRoll * Double(move.accuracy ?? 100) / 100
    }

    /// Tunable weights collected in one place so the scoring functions
    /// read as descriptions, not magic constants. Additive weights are in
    /// HP-of-damage points; `...Mult` values multiply the score.
    public enum Weights {
        /// Sentinel for moves that can't work; far below any real score.
        public static let disallowed: Double = -100
        /// Bonus for a KO, scaled by the chance of getting it. Ending the
        /// fight is worth more than the HP it removes.
        public static let koBonus: Double = 40
        /// Bonus when two hits would KO, so the AI prefers attacks that
        /// set up a KO next turn.
        public static let twoHitKOBonus: Double = 10
        /// Mean of the engine's 85-100% damage roll.
        public static let averageRoll: Double = DamageCalculator.averageRoll
        /// Discount on value that only pays off over future turns, which
        /// may never come (crits, misses, a faster KO).
        public static let futureDiscount: Double = 0.75
        /// How many future actions count when pricing boosts, statuses and
        /// heals. Short fights mean long-term value is speculative.
        public static let horizon: Int = 2
        /// In-battle penalty per turn of the current streak of one move.
        public static let repeatPenalty: Double = 3
        /// Multiplier on a support move's in-battle score per non-attacking
        /// move the AI just used in a row.
        public static let supportStreakDecay: Double = 0.5
        public static let rechargeRecentMult: Double = 0.2
        public static let redundantStatusPenalty: Double = 25
    }
}

// MARK: - Outlook

extension MoveScoring {
    /// A rough forecast of the fight from the fighter's point of view, used
    /// to price moves whose value plays out over several turns.
    struct Outlook {
        /// Best expected damage per action, each way.
        let ourDamage: Double
        let theirDamage: Double
        /// The opponent's best top-roll damage and the chance (its
        /// accuracy) that it lands, for the speed-threat check.
        let theirMaxDamage: Int
        let theirKOChance: Double
        /// Strictly faster; a tie is a coin flip, flagged by ``speedTie``.
        let weMoveFirst: Bool
        let speedTie: Bool
        /// Actions each side gets before fainting (including this turn's),
        /// capped at ``cap``. On a speed tie each side is half a turn
        /// ahead on average, hence the fractions.
        let ourActions: Double
        let theirActions: Double
        let fighterHP: Int

        static let cap = 6.0

        /// Whether the opponent's best move can KO the fighter this turn.
        var isThreatened: Bool { theirMaxDamage >= fighterHP }

        init(fighter: Combatant, opponent: Combatant, typeChart: some TypeEffectivenessProviding) {
            let ours = MoveScoring.best(attacker: fighter, defender: opponent, typeChart: typeChart)
            let theirs = MoveScoring.best(attacker: opponent, defender: fighter, typeChart: typeChart)
            ourDamage = ours.expected
            theirDamage = theirs.expected
            theirMaxDamage = theirs.maxDamage
            theirKOChance = theirs.maxDamage >= fighter.currentHP ? theirs.accuracy : 0
            weMoveFirst = fighter.effectiveSpeed > opponent.effectiveSpeed
            speedTie = fighter.effectiveSpeed == opponent.effectiveSpeed
            fighterHP = fighter.currentHP
            let hitsWeTake = Self.hits(toKO: fighter.currentHP, at: theirs.expected)
            let hitsTheyTake = Self.hits(toKO: opponent.currentHP, at: ours.expected)
            // Moving first means getting an action in before each hit taken.
            let ourHeadStart = speedTie ? 0.5 : (weMoveFirst ? 1 : 0)
            ourActions = max(0, min(Self.cap, hitsWeTake - 1 + ourHeadStart))
            theirActions = max(0, min(Self.cap, hitsTheyTake - ourHeadStart))
        }

        static func hits(toKO hp: Int, at damage: Double) -> Double {
            guard damage > 0 else { return cap + 1 }
            return (Double(hp) / damage).rounded(.up)
        }
    }

    /// The attacker's best usable move by expected damage. A combatant
    /// without moves is assumed to have an 80-power same-type attack.
    static func best(
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> (expected: Double, maxDamage: Int, accuracy: Double) {
        let moves = attacker.moves.isEmpty ? [probeMove(for: attacker, against: defender, typeChart: typeChart)] : attacker.moves
        var result: (expected: Double, maxDamage: Int, accuracy: Double) = (0, 0, 0)
        for move in moves where move.isDamage {
            let expected = expectedDamage(move, attacker: attacker, defender: defender, typeChart: typeChart)
            if expected > result.expected {
                let maxDamage = DamageCalculator.estimateDamage(move: move, attacker: attacker, defender: defender, typeChart: typeChart)
                result = (expected, maxDamage, Double(move.accuracy ?? 100) / 100)
            }
        }
        return result
    }

    /// Stand-in attack for a combatant whose moves aren't known: 80 power,
    /// its best same-type matchup, in its better attacking stat.
    static func probeMove(
        for attacker: Combatant,
        against defender: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> MoveSnapshot {
        let type = attacker.typeNames.max {
            typeChart.multiplier(attacking: $0, defenders: defender.typeNames)
                < typeChart.multiplier(attacking: $1, defenders: defender.typeNames)
        } ?? "normal"
        let damageClass: DamageClass = attacker.attack >= attacker.specialAttack ? .physical : .special
        return MoveSnapshot(
            name: "probe", displayName: "Probe", power: 80, accuracy: 100, priority: 0,
            damageClass: damageClass.rawValue, typeName: type, ailment: "none", ailmentChance: 0,
            drain: 0, healing: 0, effectChance: nil, statChangeNames: [], statChangeDeltas: [],
            isRechargeMove: false, hasSelfDebuff: false
        )
    }
}

// MARK: - Private
private extension MoveScoring {

    /// See ``score(move:fighter:opponent:typeChart:)`` for the breakdown.
    static func damageScore(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        outlook: Outlook,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        let accuracy = Double(move.accuracy ?? 100) / 100
        let estimate = Double(DamageCalculator.estimateDamage(move: move, attacker: fighter, defender: opponent, typeChart: typeChart))
        let hp = Double(opponent.currentHP)
        let dealt = min(estimate * Weights.averageRoll, hp)

        // The roll is uniform in 85-100% of the top damage, so the chance it
        // covers the remaining HP is linear across that range.
        let rollKOChance: Double = {
            if estimate * 0.85 >= hp { return 1 }
            if estimate < hp { return 0 }
            return (estimate - hp) / (estimate * 0.15)
        }()
        // Focus Punch fails if its user is hit first, and with -3
        // priority it always goes last: against an opponent that can
        // attack, it's only worth what it does if the opponent doesn't.
        let landChance = move.name == "focus-punch" && outlook.theirDamage > 0 ? 0.1 : 1.0
        let koChance = rollKOChance * accuracy * landChance

        var score = dealt * accuracy * landChance + Weights.koBonus * koChance
        if rollKOChance == 0, estimate * 2 >= hp { score += Weights.twoHitKOBonus * accuracy }

        // Secondary effects only matter if the fight goes on.
        let goesOn = 1 - koChance
        let effectChance = move.effectChance.map { Double($0) / 100 } ?? 1
        score += effectValue(of: move, chance: effectChance, fighter: fighter, opponent: opponent, outlook: outlook, typeChart: typeChart)
            * accuracy * goesOn

        if move.flinchChance > 0, outlook.weMoveFirst || move.priority > 0 {
            score += Double(move.flinchChance) / 100 * outlook.theirDamage * accuracy * goesOn
        }
        if move.drain > 0 {
            let missing = Double(fighter.maxHP - fighter.currentHP)
            score += min(dealt * Double(move.drain) / 100, missing) * 0.5 * accuracy
        } else if move.drain < 0 {
            score -= dealt * Double(-move.drain) / 100 * 0.6 * accuracy
        }
        if move.healing < 0 {
            score -= Double(fighter.baseMaxHP * -move.healing / 100) * 0.6 * accuracy
        }
        if move.isRechargeMove { score -= outlook.ourDamage * goesOn }
        return score
    }

    /// What the move's non-damage effects are worth: stat changes, the
    /// ailment, and healing. `chance` is the probability the stat changes
    /// apply (a damaging move's `effectChance`; 1 for status moves).
    /// Damaging moves' ailments use their own `ailmentChance`.
    static func effectValue(
        of move: some MoveData,
        chance: Double,
        fighter: Combatant,
        opponent: Combatant,
        outlook: Outlook,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        var value = 0.0
        let changes = move.statChanges
        if !changes.isEmpty {
            var f = fighter
            var o = opponent
            for change in changes {
                if change.target == .user { f.applyStage(change.stat, delta: change.delta) }
                else { o.applyStage(change.stat, delta: change.delta) }
            }
            value += stateChangeValue(fighter: f, opponent: o, before: outlook, typeChart: typeChart) * chance
        }

        let ailment = Status(ailment: move.ailment)
        if ailment != .none {
            let ailmentChance = move.ailmentChance > 0 ? Double(move.ailmentChance) / 100 : (move.isDamage ? 0 : 1)
            value += statusValue(ailment, isToxic: move.inflictsBadPoison, fighter: fighter, opponent: opponent, outlook: outlook, typeChart: typeChart)
                * ailmentChance
        }

        if !move.isDamage {
            if move.name == "rest" {
                value += restValue(fighter: fighter, opponent: opponent, outlook: outlook, typeChart: typeChart)
            } else if move.healing > 0 {
                var f = fighter
                f.currentHP = min(f.maxHP, f.currentHP + f.baseMaxHP * move.healing / 100)
                value += (Outlook(fighter: f, opponent: opponent, typeChart: typeChart).ourActions - outlook.ourActions)
                    * outlook.ourDamage * Weights.futureDiscount
            }
        }
        return value
    }

    /// Damage gained or prevented over the next few actions by moving from
    /// the current state (`before`) to `fighter` and `opponent`. Offensive
    /// gains count for the fighter's next ``Weights/horizon`` actions after
    /// this one, defensive gains for the opponent's next actions, and
    /// flipping the turn order is worth half a hit.
    static func stateChangeValue(
        fighter: Combatant,
        opponent: Combatant,
        before: Outlook,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        let after = Outlook(fighter: fighter, opponent: opponent, typeChart: typeChart)
        let ourFuture = max(0, min(before.ourActions - 1, Double(Weights.horizon)))
        let theirFuture = min(before.theirActions, Double(Weights.horizon + 1))
        var value = (after.ourDamage - before.ourDamage) * ourFuture
            + (before.theirDamage - after.theirDamage) * theirFuture
        if after.weMoveFirst, !before.weMoveFirst { value += before.ourDamage * 0.5 * min(1, ourFuture) }
        if !after.weMoveFirst, before.weMoveFirst { value -= before.theirDamage * 0.5 }
        // A boost can't be worth more than finishing the opponent.
        return min(value, Double(opponent.currentHP)) * Weights.futureDiscount
    }

    /// Value of inflicting `ailment` on the opponent: 0 if it already has a
    /// status or its type is immune. Each ailment is priced by what it
    /// does in the engine: lost actions for sleep and full paralysis, the
    /// Speed drop and burn's Attack cut via ``stateChangeValue(fighter:opponent:before:typeChart:)``,
    /// and residual damage for burn and (bad) poison.
    static func statusValue(
        _ ailment: Status,
        isToxic: Bool,
        fighter: Combatant,
        opponent: Combatant,
        outlook: Outlook,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        guard opponent.status == .none, !ailment.isImmune(typeNames: opponent.typeNames) else { return 0 }
        var statused = opponent
        statused.status = ailment
        var value = ailment == .sleep ? 0 : stateChangeValue(fighter: fighter, opponent: statused, before: outlook, typeChart: typeChart)

        let theirFuture = min(outlook.theirActions, Double(Weights.horizon + 1))
        let rounds = min(max(outlook.ourActions, outlook.theirActions), Double(Weights.horizon + 1)).rounded()
        let maxHP = Double(opponent.baseMaxHP)
        switch ailment {
        case .sleep:
            // Sleep lasts 1-3 turns, two on average.
            value += outlook.theirDamage * min(2, theirFuture)
        case .freeze:
            // A 20% thaw chance each turn: the opponent expects to lose
            // 0.8 + 0.64 + ... of its next actions.
            let lost = (0..<Int(theirFuture.rounded(.up))).reduce(0.0) { sum, k in sum + pow(0.8, Double(k + 1)) }
            value += outlook.theirDamage * lost
        case .paralysis:
            value += outlook.theirDamage * 0.25 * theirFuture * Weights.futureDiscount
        case .burn:
            value += maxHP / 16 * rounds * Weights.futureDiscount
        case .poison:
            let ticks = isToxic
                ? (1...max(1, Int(rounds))).reduce(0.0) { $0 + Double($1) / 16 }
                : rounds / 8
            value += maxHP * ticks * Weights.futureDiscount
        case .none:
            break
        }
        return min(value, Double(opponent.currentHP))
    }

    /// Rest heals up to the real level-50 HP and cures status, but the user then sleeps for two
    /// turns: worth the extra actions it buys minus those two.
    static func restValue(
        fighter: Combatant,
        opponent: Combatant,
        outlook: Outlook,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        var rested = fighter
        rested.currentHP = min(rested.maxHP, rested.currentHP + rested.baseMaxHP)
        rested.status = .none
        let after = Outlook(fighter: rested, opponent: opponent, typeChart: typeChart)
        return (after.ourActions - outlook.ourActions - 2) * outlook.ourDamage * Weights.futureDiscount
    }
}
