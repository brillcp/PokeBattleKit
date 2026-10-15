/// How hard a damaging move hits in a given situation.
public enum MovePower: Equatable, Sendable {
    /// Power for the damage formula.
    case power(Int)
    /// A set amount of HP, bypassing the formula (Seismic Toss, Super Fang).
    /// Already scaled to battle HP.
    case fixed(Int)
}

/// Facts about the current turn that some moves' power depends on.
public struct TurnContext: Sendable, Equatable {
    /// The attacker acts before the defender this turn (Bolt Beak doubles,
    /// Payback doesn't).
    public var attackerMovesFirst: Bool
    /// The attacker took damage earlier this turn (Avalanche, Revenge).
    public var attackerWasHit: Bool
    /// The defender took damage earlier this turn (Assurance).
    public var defenderWasHit: Bool

    public init(attackerMovesFirst: Bool, attackerWasHit: Bool = false, defenderWasHit: Bool = false) {
        self.attackerMovesFirst = attackerMovesFirst
        self.attackerWasHit = attackerWasHit
        self.defenderWasHit = defenderWasHit
    }

    /// The expected context for `move`, used when planning a move rather
    /// than resolving one: the attacker moves first if its move has higher
    /// priority or it's faster, and moving second means it was probably
    /// hit first.
    public static func predicted(move: some MoveData, attacker: Combatant, defender: Combatant) -> TurnContext {
        let first = move.priority > 0 || attacker.effectiveSpeed > defender.effectiveSpeed
        return TurnContext(attackerMovesFirst: first, attackerWasHit: !first, defenderWasHit: false)
    }
}

public extension DamageCalculator {

    /// The power or fixed damage of `move` when `attacker` uses it on
    /// `defender`, or `nil` if it doesn't deal damage. Covers the moves in
    /// ``MoveClassification/computedPowerMoves`` and
    /// ``MoveClassification/fixedDamageMoves``, following the main games:
    ///
    /// - Return, Frustration (and Let's Go's Pika Papow, Veevee Volley):
    ///   102, their power at maximum (or minimum) friendship.
    /// - Low Kick, Grass Knot: 20-120 by the target's weight. Heavy Slam,
    ///   Heat Crash: 40-120 by how many times heavier the user is. Unknown
    ///   weights count as a middling 60.
    /// - Reversal, Flail: 20-200, higher the less HP the user has left.
    ///   Hard Press (up to 100), Wring Out and Crush Grip (up to 120):
    ///   higher the more HP the target has left.
    /// - Gyro Ball (up to 150): faster targets take more. Electro Ball:
    ///   40-150 by how many times faster the user is.
    /// - Stored Power, Power Trip: 20 plus 20 per stat boost on the user.
    ///   Punishment: 60 plus 20 per boost on the target, up to 200.
    /// - Magnitude: 10-150 at random (71 on average).
    /// - Double power when the condition holds: Facade (user has a
    ///   status), Hex (target has one), Venoshock (target is poisoned),
    ///   Brine (target at half HP or less), Acrobatics (always: there are
    ///   no held items), Avalanche and Revenge (user was hit first),
    ///   Payback (user moves second), Bolt Beak and Fishious Rend (user
    ///   moves first), Assurance (target was already hit this turn).
    /// - Fixed damage: Seismic Toss and Night Shade deal the user's level,
    ///   Psywave 0.5-1.5x the level, Dragon Rage 40 and Sonic Boom 20. Like
    ///   every other hit they're real-game amounts, so they keep their
    ///   real-game strength relative to attacks. Super Fang, Nature's
    ///   Madness and Ruination take half the target's HP *as the games
    ///   count it*: half of its real HP share (current HP divided by the
    ///   HP bulk), so with extra bulk they're still worth about one hit,
    ///   not several. Endeavor cuts the target's HP to the user's.
    ///
    /// - Parameter randomized: Roll Magnitude and Psywave (the engine);
    ///   otherwise use their averages (planning).
    static func power(
        of move: some MoveData,
        attacker: Combatant,
        defender: Combatant,
        context: TurnContext,
        randomized: Bool = false
    ) -> MovePower? {
        let base = move.power ?? 0
        let bulk = Double(defender.maxHP) / Double(max(1, defender.baseMaxHP))
        func fixed(_ amount: Double) -> MovePower { .fixed(max(1, Int(amount))) }
        func doubled(if condition: Bool) -> MovePower { .power(condition ? base * 2 : base) }

        switch move.name {
        case "return", "frustration", "pika-papow", "veevee-volley":
            return .power(102)
        case "low-kick", "grass-knot":
            return .power(weightPower(defender.weight))
        case "heavy-slam", "heat-crash":
            return .power(weightRatioPower(attacker.weight, defender.weight))
        case "reversal", "flail":
            let p = 48 * attacker.currentHP / max(1, attacker.maxHP)
            return .power(p <= 1 ? 200 : p <= 4 ? 150 : p <= 9 ? 100 : p <= 16 ? 80 : p <= 32 ? 40 : 20)
        case "hard-press":
            return .power(max(1, 100 * defender.currentHP / max(1, defender.maxHP)))
        case "wring-out", "crush-grip":
            return .power(max(1, 120 * defender.currentHP / max(1, defender.maxHP)))
        case "gyro-ball":
            return .power(min(150, 25 * defender.effectiveSpeed / max(1, attacker.effectiveSpeed) + 1))
        case "electro-ball":
            let ratio = Double(attacker.effectiveSpeed) / Double(max(1, defender.effectiveSpeed))
            return .power(ratio >= 4 ? 150 : ratio >= 3 ? 120 : ratio >= 2 ? 80 : ratio >= 1 ? 60 : 40)
        case "stored-power", "power-trip":
            return .power(20 + 20 * attacker.statStages.values.filter { $0 > 0 }.reduce(0, +))
        case "punishment":
            return .power(min(200, 60 + 20 * defender.statStages.values.filter { $0 > 0 }.reduce(0, +)))
        case "magnitude":
            return .power(randomized ? magnitudeRoll() : 71)
        case "facade":
            return doubled(if: attacker.status != .none && attacker.status != .sleep && attacker.status != .freeze)
        case "hex":
            return doubled(if: defender.status != .none)
        case "venoshock":
            return doubled(if: defender.status == .poison)
        case "brine":
            return doubled(if: defender.currentHP * 2 <= defender.maxHP)
        case "acrobatics":
            return doubled(if: true)
        case "avalanche", "revenge":
            return doubled(if: context.attackerWasHit)
        case "payback":
            return doubled(if: !context.attackerMovesFirst)
        case "bolt-beak", "fishious-rend":
            return doubled(if: context.attackerMovesFirst)
        case "assurance":
            return doubled(if: context.defenderWasHit)
        case "seismic-toss", "night-shade":
            return fixed(Double(attacker.level))
        case "psywave":
            return fixed(Double(attacker.level) * (randomized ? Double.random(in: 0.5...1.5) : 1))
        case "dragon-rage":
            return fixed(40)
        case "sonic-boom":
            return fixed(20)
        case "super-fang", "natures-madness", "ruination":
            return .fixed(max(1, Int(Double(defender.currentHP) / bulk / 2)))
        case "endeavor":
            return .fixed(max(0, defender.currentHP - attacker.currentHP))
        default:
            return base > 0 ? .power(base) : nil
        }
    }
}

private extension DamageCalculator {
    /// Low Kick / Grass Knot power by the target's weight in kilograms.
    static func weightPower(_ hectograms: Int?) -> Int {
        guard let hectograms else { return 60 }
        let kg = Double(hectograms) / 10
        switch kg {
        case ..<10: return 20
        case ..<25: return 40
        case ..<50: return 60
        case ..<100: return 80
        case ..<200: return 100
        default: return 120
        }
    }

    /// Heavy Slam / Heat Crash power by how many times heavier the user is.
    static func weightRatioPower(_ user: Int?, _ target: Int?) -> Int {
        guard let user, let target, target > 0 else { return 60 }
        let ratio = Double(user) / Double(target)
        return ratio >= 5 ? 120 : ratio >= 4 ? 100 : ratio >= 3 ? 80 : ratio >= 2 ? 60 : 40
    }

    /// Magnitude 4-10: 10, 30, 50, 70, 90, 110, 150 power with
    /// 5/10/20/30/20/10/5% odds.
    static func magnitudeRoll() -> Int {
        let roll = Double.random(in: 0..<1)
        let table: [(Double, Int)] = [(0.05, 10), (0.15, 30), (0.35, 50), (0.65, 70), (0.85, 90), (0.95, 110), (1.0, 150)]
        return table.first { roll < $0.0 }?.1 ?? 150
    }
}
