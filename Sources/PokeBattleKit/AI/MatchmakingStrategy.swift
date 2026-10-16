/// Sendable DTO carrying the fields the AI needs to evaluate a potential
/// battle candidate. Pure data; heuristics live in ``MatchmakingStrategy``.
public struct Candidate: Sendable {
    public let id: Int
    /// PokeAPI name, used to look up its ``strength``.
    public let name: String
    public let typeNames: [String]
    /// Sum of the six base stats (BST); only used to estimate ``strength``
    /// for Pokémon without a simulated rating.
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

    /// Simulated battle strength (see ``PokemonStrength``).
    public var strength: Double {
        PokemonStrength.rating(forPokemonNamed: name, baseStatTotal: baseStatTotal)
    }
}

/// Matchmaking: fair matchups between two candidates by simulated battle
/// strength.
///
/// The rules are symmetric, so the same calls find an opponent for the
/// player's fighter or a fighter for the player against a given opponent:
/// pass whichever side is already chosen as the first argument (named
/// `player` for source compatibility) and the other side's options as
/// `candidates`. Two candidates are a fair match when:
/// - **Strength:** either one's predicted win chance against the other
///   (from ``PokemonStrength`` ratings) is within ``fairWinChance``, so
///   neither side is expected to win easily, and
/// - **Types:** neither side's types hit the other super-effectively while
///   being resisted back (a one-sided matchup), and neither is immune to
///   all of the other's types.
///
/// Difficulty doesn't change who's fair; it changes the AI opponent's level
/// and play (see ``Difficulty``). ``pick(for:from:typeChart:excluding:using:)``
/// then chooses among the fair matches at random, favouring the tensest
/// matchups, so repeated picks vary.
public enum MatchmakingStrategy {

    /// The range a fair matchup's predicted win chance falls in. It's
    /// centred on 50%, so it holds from either side's point of view.
    public static let fairWinChance: ClosedRange<Double> = 0.35...0.65

    /// The predicted chance that `player` (the first candidate, whichever
    /// side it's on) beats `candidate` at equal level. The chance the other
    /// way round is one minus this.
    public static func predictedWinChance(of player: Candidate, against candidate: Candidate) -> Double {
        PokemonStrength.winChance(rating: player.strength, against: candidate.strength)
    }

    /// Every fair match for `player` (the side already chosen) among
    /// `candidates`, other than `player` itself, in random order. When
    /// none qualify (an outlier Pokémon), the closest matches
    /// by predicted win chance that pass the type check are returned
    /// instead, and failing that the closest matches at all.
    public static func fairPool(
        for player: Candidate,
        from candidates: [Candidate],
        typeChart: (some TypeEffectivenessProviding)?,
        using generator: inout some RandomNumberGenerator
    ) -> [Candidate] {
        let others = candidates.filter { $0.id != player.id }
        let typeFair = others.filter { isTypeFair(player: player, candidate: $0, typeChart: typeChart) }
        let fair = typeFair.filter { fairWinChance.contains(predictedWinChance(of: player, against: $0)) }
        if !fair.isEmpty { return fair.shuffled(using: &generator) }
        let fallback = typeFair.isEmpty ? others : typeFair
        let closest = fallback
            .sorted { abs(predictedWinChance(of: player, against: $0) - 0.5) < abs(predictedWinChance(of: player, against: $1) - 0.5) }
            .prefix(max(1, fallback.count / 20))
        return Array(closest).shuffled(using: &generator)
    }

    /// ``fairPool(for:from:typeChart:using:)`` with the system random
    /// number generator.
    public static func fairPool(
        for player: Candidate,
        from candidates: [Candidate],
        typeChart: (some TypeEffectivenessProviding)?
    ) -> [Candidate] {
        var generator = SystemRandomNumberGenerator()
        return fairPool(for: player, from: candidates, typeChart: typeChart, using: &generator)
    }

    /// A match for `player` (the side already chosen) from `candidates`: a
    /// random fair match, weighted towards tense matchups (a predicted win
    /// chance near 50%, and both sides able to hit the other
    /// super-effectively). Candidates in `recent`
    /// are skipped while others remain, so repeated picks vary. `nil` only
    /// if there are no other candidates.
    public static func pick(
        for player: Candidate,
        from candidates: [Candidate],
        typeChart: (some TypeEffectivenessProviding)?,
        excluding recent: Set<Int> = [],
        using generator: inout some RandomNumberGenerator
    ) -> Candidate? {
        let pool = fairPool(for: player, from: candidates, typeChart: typeChart, using: &generator)
        let fresh = pool.filter { !recent.contains($0.id) }
        let options = fresh.isEmpty ? pool : fresh
        let weights = options.map { tension(player: player, candidate: $0, typeChart: typeChart) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return options.first }
        var roll = Double.random(in: 0..<total, using: &generator)
        for (option, weight) in zip(options, weights) {
            if roll < weight { return option }
            roll -= weight
        }
        return options.last
    }

    /// ``pick(for:from:typeChart:excluding:using:)`` with the system random
    /// number generator.
    public static func pick(
        for player: Candidate,
        from candidates: [Candidate],
        typeChart: (some TypeEffectivenessProviding)?,
        excluding recent: Set<Int> = []
    ) -> Candidate? {
        var generator = SystemRandomNumberGenerator()
        return pick(for: player, from: candidates, typeChart: typeChart, excluding: recent, using: &generator)
    }
}

// MARK: - Private
private extension MatchmakingStrategy {

    /// Rejects one-sided type matchups: a side whose best same-type (STAB)
    /// multiplier is super effective while the other's is under 1.5x, or a
    /// side immune to everything the other's types throw. Passes when type
    /// data is missing.
    static func isTypeFair(
        player: Candidate,
        candidate: Candidate,
        typeChart: (some TypeEffectivenessProviding)?
    ) -> Bool {
        guard let typeChart, !player.typeNames.isEmpty, !candidate.typeNames.isEmpty else { return true }
        let theirs = typeChart.bestSTABMultiplier(attackerTypes: candidate.typeNames, defenderTypes: player.typeNames)
        let yours = typeChart.bestSTABMultiplier(attackerTypes: player.typeNames, defenderTypes: candidate.typeNames)
        if theirs >= 2, yours < 1.5 { return false }
        if yours >= 2, theirs < 1.5 { return false }
        return theirs > 0 && yours > 0
    }

    /// Weight for ``pick(for:from:typeChart:excluding:using:)``: 1 at a
    /// predicted 50/50, falling to 0.3 at the edge of the fair range, and
    /// doubled when both sides can hit the other super-effectively.
    static func tension(
        player: Candidate,
        candidate: Candidate,
        typeChart: (some TypeEffectivenessProviding)?
    ) -> Double {
        let chance = predictedWinChance(of: player, against: candidate)
        let halfWidth = (fairWinChance.upperBound - fairWinChance.lowerBound) / 2
        let closeness = max(0.3, 1 - abs(chance - 0.5) / halfWidth * 0.7)
        guard let typeChart else { return closeness }
        let theirs = typeChart.bestSTABMultiplier(attackerTypes: candidate.typeNames, defenderTypes: player.typeNames)
        let yours = typeChart.bestSTABMultiplier(attackerTypes: player.typeNames, defenderTypes: candidate.typeNames)
        return closeness * (theirs >= 2 && yours >= 2 ? 2 : 1)
    }
}
