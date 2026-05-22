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
    /// Pass `onProgress` to receive status updates during fetching.
    public static func initialize(
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        guard !_isInitialized else { return }

        let typeChart = try await loadTypeChart(onProgress: onProgress)
        let moves = try await loadMoves(onProgress: onProgress)

        _typeChart = typeChart
        _moves = Dictionary(uniqueKeysWithValues: moves.map { ($0.name, $0) })
        _isInitialized = true

        onProgress?(.done)
    }

    /// Progress updates emitted during ``initialize()``.
    public enum Progress: Sendable {
        case loadingTypeChart
        case typeChartReady
        case loadingMoves
        case movesProgress(fetched: Int, total: Int)
        case movesReady
        case done
    }
}

// MARK: - Private

private extension PokeBattleKit {
    static func loadTypeChart(
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> TypeChart {
        if let cached: TypeChart = cache.load(TypeChart.self, from: typeChartFile) {
            onProgress?(.typeChartReady)
            return cached
        }

        onProgress?(.loadingTypeChart)
        let responses = try await client.fetchTypes()
        let chart = TypeChart(from: responses)
        try? cache.save(chart, to: typeChartFile)
        onProgress?(.typeChartReady)
        return chart
    }

    static func loadMoves(
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> [Move] {
        if let cached = cache.load([Move].self, from: movesFile) {
            onProgress?(.movesReady)
            return cached
        }

        onProgress?(.loadingMoves)
        let names = try await client.fetchMoveNames()
        let total = names.count
        var allMoves: [Move] = []
        allMoves.reserveCapacity(total)

        let chunkSize = 25
        for chunkStart in stride(from: 0, to: total, by: chunkSize) {
            let chunk = Array(names[chunkStart..<min(chunkStart + chunkSize, total)])
            let responses = try await client.fetchMoves(named: chunk, chunkSize: chunk.count)
            let moves = responses.map { Move(from: $0) }
            allMoves.append(contentsOf: moves)
            onProgress?(.movesProgress(fetched: allMoves.count, total: total))
        }

        try? cache.save(allMoves, to: movesFile)
        onProgress?(.movesReady)
        return allMoves
    }
}
