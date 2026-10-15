/// How hard the AI opponent is.
///
/// The main lever is the classic one: the opponent's level
/// (``opponentLevelOffset``, applied by ``BattleRules/opponentLevel(for:)``).
/// The offsets are calibrated with the balance simulation so a player who
/// plays well wins about ``targetPlayerWinRate`` of battles: 90% on easy,
/// 50% on fair, 20% on hard. The AI's play style changes with it, through
/// the strategies that make choices on its behalf:
/// - ``easy``: the AI's loadout gets a deliberately weak attack (see
///   ``LoadoutStrategy/adjust(picks:pool:fighter:opponent:typeChart:difficulty:)``),
///   and it picks loosely among its decent moves, so the player gets openings.
/// - ``fair``: same level, no handicaps. The AI picks among the moves that
///   score within about 10% of its best one, weighted by score, so it plays
///   well without being predictable.
/// - ``hard``: a higher-level opponent that always plays its best move.
public enum Difficulty: String, Sendable, Codable, CaseIterable {
    case easy
    case fair
    case hard

    /// Levels the AI opponent is above (positive) or below (negative) the
    /// player. Calibrated with `PokedexSimulationTests.calibrateDifficulty` to hit
    /// ``targetPlayerWinRate``; rerun the calibration after changing the
    /// AI or the battle rules.
    public var opponentLevelOffset: Int {
        switch self {
        case .easy: -6
        case .fair: 0
        case .hard: 7
        }
    }

    /// The share of battles a good player should win at this difficulty.
    public var targetPlayerWinRate: Double {
        switch self {
        case .easy: 0.9
        case .fair: 0.5
        case .hard: 0.2
        }
    }
}
