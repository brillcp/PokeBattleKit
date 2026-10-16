/// The tunable rules of a battle, passed to ``Combatant/init(pokemon:moves:rules:level:hpBonus:)``.
///
/// Nothing about battle length is a fixed constant: it follows from two
/// design choices.
/// - ``level``: the player's level, and the base level both sides' HP is
///   scaled from. The AI opponent's level varies with the difficulty
///   (``opponentLevel(for:)``). Stats and damage use the main-series
///   formulas at each combatant's level.
/// - ``referenceHitsToKO``: how many hits of a *reference attack* it should
///   take to knock out a *reference Pokémon*. The reference is an 80-power
///   same-type attack between two Pokémon with a base of 80 in every stat,
///   at the average damage roll: a typical, evenly matched exchange.
///
/// Max HP is then scaled by ``hpMultiplier`` so that the reference holds at
/// whatever level you pick. At real-game HP a one-on-one fight without
/// switching is over in a hit or two (a super-effective same-type move
/// nearly one-shots), so the standard rules aim for 12 reference hits,
/// which works out to fights of around six turns. Each hit still does
/// real-game damage, and anything the games define as a share of max HP
/// (healing, Rest, burn and poison damage) uses the real HP
/// (``Combatant/baseMaxHP``), so it keeps its real-game size relative to
/// attacks.
public struct BattleRules: Sendable, Codable, Hashable {
    public var level: Int
    /// Reference hits to KO; `nil` means real-game HP (no extra bulk).
    public var referenceHitsToKO: Double?

    public init(level: Int = 50, referenceHitsToKO: Double? = 12) {
        self.level = level
        self.referenceHitsToKO = referenceHitsToKO
    }

    /// Level 50, fights of around six turns.
    public static let standard = BattleRules()

    /// The AI opponent's level at `difficulty`: ``level`` plus
    /// ``Difficulty/opponentLevelOffset``, kept within 1...100.
    public func opponentLevel(for difficulty: Difficulty) -> Int {
        min(100, max(1, level + difficulty.opponentLevelOffset))
    }

    /// Level 50 at real-game HP: faithful to the cartridge, but most
    /// fights end within two turns.
    public static let realGameHP = BattleRules(referenceHitsToKO: nil)

    /// Max HP as a multiple of the real HP, derived from
    /// ``referenceHitsToKO`` at ``level``. Never below 1.
    public var hpMultiplier: Double {
        guard let referenceHitsToKO else { return 1 }
        let base = 80
        let stat = Double(Combatant.stat(base: base, level: level))
        let hp = Double(Combatant.hpStat(base: base, level: level))
        let hit = DamageCalculator.formulaDamage(level: level, power: 80, attack: stat, defense: stat)
            * DamageCalculator.stabMultiplier * DamageCalculator.averageRoll
        return max(1, referenceHitsToKO * hit / hp)
    }
}
