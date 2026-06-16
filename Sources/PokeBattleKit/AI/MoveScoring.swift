/// Move-evaluation primitive used by both move-pick and loadout-pick
/// strategies. Mixes damage estimates with heuristic weights for status
/// effects, stat changes, and move quirks (self-debuff, recharge,
/// priority). Higher score = better for the fighter.
public enum MoveScoring {

    public static func score(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        if MoveClassification.requiresPoisonedTarget.contains(move.name),
           opponent.status != .poison {
            return Weights.disallowed
        }
        if move.isDamage, move.damageClassKind != .status {
            return damageScore(move: move, fighter: fighter, opponent: opponent, typeChart: typeChart)
        }
        return supportScore(move: move, fighter: fighter, opponent: opponent)
    }

    /// In-battle score layering recency, recharge, and HP-aware bonuses
    /// on top of the base score. `recentMoves` is the rolling window of
    /// move names the AI has picked on prior turns (newest last).
    public static func inBattleScore(
        move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        typeChart: some TypeEffectivenessProviding,
        recentMoves: [String]
    ) -> Double {
        var score = Self.score(move: move, fighter: attacker, opponent: defender, typeChart: typeChart)

        let consecutiveUses = recentMoves.suffix(4).reversed()
            .prefix(while: { $0 == move.name }).count
        switch consecutiveUses {
        case 3...: score -= Weights.repeatThird
        case 2:    score -= Weights.repeatSecond
        case 1:    score -= Weights.repeatFirst
        default:
            if recentMoves.contains(move.name) { score -= Weights.usedRecently }
        }

        if move.isRechargeMove,
           recentMoves.contains(where: { MoveClassification.rechargeMoves.contains($0) }) {
            score *= Weights.rechargeRecentMult
        }

        if (move.power ?? 0) == 0 {
            for (index, stat) in move.statChangeNames.enumerated() where index < move.statChangeDeltas.count {
                if move.statChangeDeltas[index] > 0, attacker.stage(for: stat) >= 2 {
                    score -= Weights.wastedBoostPenalty
                }
            }
        }

        if defender.status != .none, move.ailment != "none" { score -= Weights.redundantStatusPenalty }

        let hpFraction = Double(attacker.currentHP) / Double(max(1, attacker.maxHP))
        if hpFraction <= 0.30 {
            if move.healing > 0 || move.name == "rest" { score += Weights.lowHPHealBonus }
            if move.priority > 0, (move.power ?? 0) > 0 { score += Weights.lowHPPriorityBonus }
        }

        return score
    }

    /// Tunable weights collected in one place so the scoring functions
    /// read as descriptions, not magic constants.
    public enum Weights {
        public static let disallowed: Double      = -100
        public static let koBonus: Double         = 55
        public static let nearKOBonus: Double     = 18
        public static let resistedMult: Double    = 0.4
        public static let selfDebuffPenalty: Double = 18
        public static let priorityBonus: Double   = 8
        public static let rechargeMult: Double    = 0.45

        public static let healingVsBulky: Double  = 16
        public static let healingDefault: Double  = 8

        public static let statusMinChance: Int    = 60
        public static let paralysisFaster: Double = 28
        public static let paralysisSlower: Double = 12
        public static let burnPhysical: Double    = 24
        public static let burnSpecial: Double     = 10
        public static let poisonBulky: Double     = 18
        public static let poisonFrail: Double     = 8
        public static let sleep: Double           = 22
        public static let statusOther: Double     = 4

        public static let statBoostMatching: Double   = 10
        public static let statBoostMismatch: Double   = 2
        public static let statBoostSpeedSlow: Double  = 16
        public static let statBoostSpeedFast: Double  = 2
        public static let statBoostDefVsTank: Double  = 7
        public static let statBoostDefVsFrail: Double = 4
        public static let statBoostDefault: Double    = 4

        public static let statDebuffMatching: Double = 8
        public static let statDebuffMismatch: Double = 3
        public static let statDebuffDefault: Double  = 4

        // In-battle recency (escalating)
        public static let repeatFirst: Double         = 18
        public static let repeatSecond: Double        = 40
        public static let repeatThird: Double         = 65
        public static let usedRecently: Double        = 15
        public static let rechargeRecentMult: Double  = 0.2
        public static let wastedBoostPenalty: Double   = 18
        public static let redundantStatusPenalty: Double = 25
        public static let lowHPHealBonus: Double      = 35
        public static let lowHPPriorityBonus: Double  = 20
    }
}

// MARK: - Private
private extension MoveScoring {

    static func damageScore(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant,
        typeChart: some TypeEffectivenessProviding
    ) -> Double {
        let effectiveness = typeChart.multiplier(attacking: move.typeName, defenders: opponent.typeNames)
        guard effectiveness > 0 else { return Weights.disallowed }
        let accuracy = Double(move.accuracy ?? 100) / 100
        let estimated = Double(DamageCalculator.estimateDamage(
            move: move, attacker: fighter, defender: opponent, typeChart: typeChart
        ))
        var score = estimated * accuracy
        if estimated >= Double(opponent.currentHP) { score += Weights.koBonus }
        if estimated >= Double(opponent.currentHP) * 0.65 { score += Weights.nearKOBonus }
        if effectiveness < 1, effectiveness > 0 { score *= Weights.resistedMult }
        if move.hasSelfDebuff { score -= Weights.selfDebuffPenalty }
        if move.priority > 0 { score += Weights.priorityBonus }
        if move.isRechargeMove { score *= Weights.rechargeMult }
        return score
    }

    static func supportScore(
        move: some MoveData,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        var score = 0.0
        if move.ailment != "none" {
            score += statusScore(ailment: move.ailment, chance: move.ailmentChance, fighter: fighter, opponent: opponent)
        }
        if move.healing > 0 || move.name == "rest" {
            score += opponent.maxHP > fighter.maxHP ? Weights.healingVsBulky : Weights.healingDefault
        }
        for (index, stat) in move.statChangeNames.enumerated() where index < move.statChangeDeltas.count {
            score += statChangeScore(stat: stat, delta: move.statChangeDeltas[index], fighter: fighter, opponent: opponent)
        }
        return score
    }

    static func statusScore(
        ailment: String,
        chance: Int,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        let factor = Double(max(chance, Weights.statusMinChance)) / 100
        switch ailment {
        case "paralysis":
            return (opponent.effectiveSpeed > fighter.effectiveSpeed ? Weights.paralysisFaster : Weights.paralysisSlower) * factor
        case "burn":
            return (opponent.attack >= opponent.specialAttack ? Weights.burnPhysical : Weights.burnSpecial) * factor
        case "poison":
            return (opponent.maxHP >= fighter.maxHP ? Weights.poisonBulky : Weights.poisonFrail) * factor
        case "sleep":
            return Weights.sleep * factor
        default:
            return Weights.statusOther * factor
        }
    }

    static func statChangeScore(
        stat: String,
        delta: Int,
        fighter: Combatant,
        opponent: Combatant
    ) -> Double {
        guard delta != 0 else { return 0 }
        let magnitude = Double(abs(delta))
        if delta > 0 {
            switch stat {
            case "speed":
                return fighter.effectiveSpeed > opponent.effectiveSpeed ? Weights.statBoostSpeedFast : Weights.statBoostSpeedSlow
            case "attack":
                return fighter.attack >= fighter.specialAttack ? magnitude * Weights.statBoostMatching : magnitude * Weights.statBoostMismatch
            case "special-attack":
                return fighter.specialAttack >= fighter.attack ? magnitude * Weights.statBoostMatching : magnitude * Weights.statBoostMismatch
            case "defense", "special-defense":
                return opponent.maxHP >= fighter.maxHP ? magnitude * Weights.statBoostDefVsTank : magnitude * Weights.statBoostDefVsFrail
            default:
                return magnitude * Weights.statBoostDefault
            }
        }
        switch stat {
        case "defense":
            return fighter.attack >= fighter.specialAttack ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        case "special-defense":
            return fighter.specialAttack >= fighter.attack ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        case "speed":
            return opponent.effectiveSpeed > fighter.effectiveSpeed ? magnitude * Weights.statDebuffMatching : magnitude * Weights.statDebuffMismatch
        default:
            return magnitude * Weights.statDebuffDefault
        }
    }
}
