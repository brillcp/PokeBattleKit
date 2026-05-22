import Foundation

/// Entry point for PokeBattleKit. Call ``initialize()`` once at app launch
/// to fetch and cache all moves and type data from PokeAPI.
public enum PokeBattleKit {
    private static let cache = DiskCache()
    private static let client = PokeAPIClient()
    private static let movesFile = "moves.json"
    private static let typeChartFile = "type_chart.json"

    private nonisolated(unsafe) static var _moves: [String: Move] = [:]
    private nonisolated(unsafe) static var _typeChart: TypeChart?
    private nonisolated(unsafe) static var _isInitialized = false

    /// Whether ``initialize()`` has completed successfully.
    public static var isInitialized: Bool { _isInitialized }

    /// The type effectiveness chart. Traps if not initialized.
    public static var typeChart: TypeChart {
        guard let chart = _typeChart else {
            preconditionFailure("PokeBattleKit.initialize() must be called before accessing typeChart")
        }
        return chart
    }

    /// All loaded moves keyed by name.
    public static var allMoves: [Move] { Array(_moves.values) }

    /// Look up a single move by its API name (e.g. "thunderbolt").
    public static func move(named name: String) -> Move? {
        _moves[name]
    }

    /// Load all moves and type data from cache or PokeAPI.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops.
    public static func initialize() async throws {
        guard !_isInitialized else { return }

        let typeChart = try await loadTypeChart()
        let moves = try await loadMoves()

        _typeChart = typeChart
        _moves = Dictionary(uniqueKeysWithValues: moves.map { ($0.name, $0) })
        _isInitialized = true
    }
}

// MARK: - Private

private extension PokeBattleKit {
    static func loadTypeChart() async throws -> TypeChart {
        if let cached = cache.load(TypeChart.self, from: typeChartFile) { return cached }
        let chart = TypeChart(from: try await client.fetchTypes())
        try? cache.save(chart, to: typeChartFile)
        return chart
    }

    static func loadMoves() async throws -> [Move] {
        if let cached = cache.load([Move].self, from: movesFile) { return cached }
        let moves = try await client.fetchMoves().map { Move(from: $0) }
        try? cache.save(moves, to: movesFile)
        return moves
    }
}
