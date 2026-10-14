/// Sendable DTO carrying the fields the AI needs to evaluate a
/// potential battle candidate. Pure data; heuristics live in
/// ``OpponentStrategy``.
public struct Candidate: Sendable {
    public let id: Int
    /// Species or form name. Names containing "mega" are treated as Mega
    /// Evolutions when scoring.
    public let name: String
    public let typeNames: [String]
    /// Sum of the six base stats (BST), the main measure of raw strength.
    public let baseStatTotal: Int
    public let isLegendary: Bool
    public let isMythical: Bool

    public init(
        id: Int,
        name: String,
        typeNames: [String],
        baseStatTotal: Int,
        isLegendary: Bool,
        isMythical: Bool
    ) {
        self.id = id
        self.name = name
        self.typeNames = typeNames
        self.baseStatTotal = baseStatTotal
        self.isLegendary = isLegendary
        self.isMythical = isMythical
    }
}

/// Heuristic AI for opponent selection. Owns the pool filter, the
/// matchup-scoring function, and the heuristic fallback used when the host
/// app's LLM picker is unavailable.
///
/// The goal is a *fair, interesting* fight rather than the strongest
/// possible opponent: similar raw strength (BST), and a type matchup where
/// both sides have something to work with. Typical flow:
/// ``balancedPool(from:playerBST:playerTypes:chart:limit:)`` narrows the
/// whole Pokedex to a shortlist (for example, to show an LLM), then
/// ``heuristicPick(player:candidates:typeChart:)`` (or the LLM) picks one.
///
/// ``heuristicPick(player:candidates:typeChart:)`` is deterministic;
/// ``balancedPool(from:playerBST:playerTypes:chart:limit:)`` shuffles, so
/// it returns a different selection each call.
public enum OpponentStrategy {

    /// Filter candidates within BST tolerance, reject hard counters,
    /// score-rank survivors, then shuffle a top slice. Falls back to the
    /// unfiltered pool if fewer than `limit` candidates survive filtering.
    ///
    /// - **BST tolerance:** keeps candidates from 120 below to 70 above the
    ///   player's BST. The window is skewed downward so the player is
    ///   rarely outclassed, while still allowing slightly stronger foes.
    /// - **Hard counters:** rejects candidates that hit the player
    ///   super-effectively while the player can't hit back at least 1.5x,
    ///   and candidates immune to all of the player's types. Skipped when
    ///   `chart` is `nil` or type data is missing.
    /// - **Ranking and variety:** survivors are ranked by BST closeness
    ///   (with a bonus for being slightly weaker) and mutual type pressure;
    ///   the top `1.5 x limit` are shuffled and `limit` of them returned,
    ///   so repeated calls give varied but still balanced opponents.
    public static func balancedPool(
        from snapshots: [Candidate],
        playerBST: Int,
        playerTypes: [String],
        chart: (some TypeEffectivenessProviding)?,
        limit: Int = 50
    ) -> [Candidate] {
        let filtered = snapshots.filter { candidate in
            let delta = candidate.baseStatTotal - playerBST
            guard delta >= -120 && delta <= 70 else { return false }
            guard let chart, !playerTypes.isEmpty, !candidate.typeNames.isEmpty else { return true }
            let candidatePressure = chart.bestSTABMultiplier(attackerTypes: candidate.typeNames, defenderTypes: playerTypes)
            let playerPressure = chart.bestSTABMultiplier(attackerTypes: playerTypes, defenderTypes: candidate.typeNames)
            if candidatePressure >= 2, playerPressure < 1.5 { return false }
            if playerPressure == 0 { return false }
            return true
        }
        let pool = filtered.count >= limit ? filtered : snapshots
        let ranked = pool.sorted { a, b in
            poolScore(a, playerBST: playerBST, playerTypes: playerTypes, chart: chart)
            > poolScore(b, playerBST: playerBST, playerTypes: playerTypes, chart: chart)
        }
        let shortlist = Array(ranked.prefix(limit + limit / 2))
        return Array(shortlist.shuffled().prefix(limit))
    }

    /// Best opponent id by full matchup scoring; nil if pool is empty.
    ///
    /// First keeps candidates within 90 below to 160 above the player's BST
    /// (a different window from
    /// ``balancedPool(from:playerBST:playerTypes:chart:limit:)``: tighter
    /// below, much looser above, leaving it to the scoring to weigh up
    /// stronger foes), falling back to all candidates if none qualify. Then
    /// returns the highest `matchupScore`; ties go to the earliest candidate.
    public static func heuristicPick(
        player: Candidate,
        candidates: [Candidate],
        typeChart: (some TypeEffectivenessProviding)?
    ) -> Int? {
        let tiered = candidates.filter { candidate in
            let delta = candidate.baseStatTotal - player.baseStatTotal
            return delta >= -90 && delta <= 160
        }
        let pool = tiered.isEmpty ? candidates : tiered
        return pool.max { lhs, rhs in
            matchupScore(player: player, candidate: lhs, typeChart: typeChart)
                < matchupScore(player: player, candidate: rhs, typeChart: typeChart)
        }?.id
    }
}

// MARK: - Private
private extension OpponentStrategy {

    /// Composite matchup score: BST closeness, type pressure, legendary
    /// and mega caveats. Used by `heuristicPick` for final ranking.
    ///
    /// "Pressure" below is the best multiplier one side's types achieve
    /// against the other's (see
    /// ``TypeEffectivenessProviding/bestSTABMultiplier(attackerTypes:defenderTypes:)``).
    static func matchupScore(
        player: Candidate,
        candidate: Candidate,
        typeChart: (some TypeEffectivenessProviding)?
    ) -> Double {
        let delta = candidate.baseStatTotal - player.baseStatTotal
        let absDelta = abs(delta)
        var score = 0.0

        // BST closeness: up to +35 within 70 points, tapering off; heavy
        // penalties beyond 90 weaker (a pushover) or 160 stronger (a wall),
        // with the weaker side penalized harder: an easy win is less fun
        // than a tough fight.
        if absDelta <= 70 {
            score += 35 - Double(absDelta) * 0.20
        } else if delta < -90 {
            score -= 70 + Double(abs(delta + 90)) * 0.35
        } else if delta > 160 {
            score -= 45 + Double(delta - 160) * 0.20
        } else {
            score += max(0, 20 - Double(absDelta - 70) * 0.15)
        }

        // Slightly weaker opponents are preferred: the player should usually
        // be able to win.
        if delta < 0, delta >= -50 { score += 12 }

        if let typeChart {
            let candidatePressure = typeChart.bestSTABMultiplier(attackerTypes: candidate.typeNames, defenderTypes: player.typeNames)
            let playerPressure = typeChart.bestSTABMultiplier(attackerTypes: player.typeNames, defenderTypes: candidate.typeNames)

            score += pressureScore(candidatePressure)
            score -= vulnerabilityPenalty(playerPressure)

            // Mutual super-effective threats make for a tense fight; a 4x
            // threat the player can't answer, or a candidate that can't
            // touch a player who hits it hard, makes for a lopsided one.
            if candidatePressure >= 1.5, playerPressure >= 1.5 { score += 18 }
            if candidatePressure >= 4, playerPressure <= 1 { score -= 25 }
            if candidatePressure < 1, playerPressure >= 2 { score -= 18 }
        }

        // Legendaries and Megas are a treat for strong players, but feel
        // unfair against an average or weak Pokemon even at a similar BST.
        if candidate.isLegendary || candidate.isMythical {
            score += player.baseStatTotal >= 500 ? 10 : -8
        }
        if candidate.name.localizedCaseInsensitiveContains("mega") {
            score += player.baseStatTotal >= 540 ? 4 : -20
        }
        return score
    }

    /// Cheaper ranking for ``balancedPool(from:playerBST:playerTypes:chart:limit:)``:
    /// BST closeness (linear, zero beyond 120 apart), +15 for being up to
    /// 60 weaker, and bonuses when both sides can hit each other: +10 for
    /// at least neutral both ways, a further +20 when both are super
    /// effective.
    static func poolScore(
        _ candidate: Candidate,
        playerBST: Int,
        playerTypes: [String],
        chart: (some TypeEffectivenessProviding)?
    ) -> Double {
        let delta = candidate.baseStatTotal - playerBST
        var score = max(0, 120.0 - Double(abs(delta)))
        if delta < 0, delta >= -60 { score += 15 }
        guard let chart, !playerTypes.isEmpty, !candidate.typeNames.isEmpty else { return score }
        let cPressure = chart.bestSTABMultiplier(attackerTypes: candidate.typeNames, defenderTypes: playerTypes)
        let pPressure = chart.bestSTABMultiplier(attackerTypes: playerTypes, defenderTypes: candidate.typeNames)
        if cPressure >= 1.5, pPressure >= 1.5 { score += 20 }
        if cPressure >= 1, pPressure >= 1 { score += 10 }
        return score
    }

    /// Reward for the candidate's pressure on the player. A 2x threat is
    /// ideal; 4x is scored much lower because it tends to mean one-sided
    /// KOs; neutral is fine; resisted or immune makes the candidate toothless.
    static func pressureScore(_ multiplier: Double) -> Double {
        if multiplier >= 4 { return 8 }
        if multiplier >= 2 { return 30 }
        if multiplier >= 1 { return 10 }
        if multiplier > 0 { return -4 }
        return -12
    }

    /// Penalty for the player's pressure on the candidate, so the opponent
    /// isn't a pushover. Negative (a bonus) when the candidate resists
    /// everything the player's types can throw at it.
    static func vulnerabilityPenalty(_ multiplier: Double) -> Double {
        if multiplier >= 4 { return 32 }
        if multiplier >= 2 { return 14 }
        if multiplier >= 1 { return 0 }
        return -8
    }
}
