import Foundation
import Synchronization

/// Entry point for PokeBattleKit. Call ``initialize()`` once at app launch
/// to fetch and cache all moves and type data from PokeAPI.
///
/// The loaded catalogue is process-wide state that's written once by
/// ``initialize()`` (usually from a background task) and read from any
/// thread afterwards (views, AI actors, the battle engine). It lives behind
/// a `Mutex`, so those reads and the one-time write are data-race free
/// under Swift 6 without `nonisolated(unsafe)`.
public enum PokeBattleKit {
    private static let cache = DiskCache()
    private static let client = PokeAPIClient()
    /// Versioned so caches written before a `Move` format change are
    /// ignored and refetched rather than failing to decode forever.
    private static let movesFile = "moves_v3.json"
    private static let typeChartFile = "type_chart.json"

    /// Everything ``initialize()`` loads, plus the in-flight load so that
    /// concurrent callers share one download instead of each starting one.
    private struct State: Sendable {
        var moves: [String: Move] = [:]
        var typeChart: TypeChart?
        var isLoaded = false
        var loading: Task<Void, any Error>?
    }

    private static let state = Mutex(State())

    /// Whether ``initialize()`` has completed successfully.
    public static var isInitialized: Bool { state.withLock(\.isLoaded) }

    /// The type effectiveness chart. Traps if not initialized; use
    /// ``loadedTypeChart`` where ``initialize()`` may not have finished.
    public static var typeChart: TypeChart {
        guard let chart = state.withLock(\.typeChart) else {
            preconditionFailure("PokeBattleKit.initialize() must be called before accessing typeChart")
        }
        return chart
    }

    /// The type effectiveness chart, or `nil` until ``initialize()`` has
    /// completed successfully. A non-trapping alternative to
    /// ``typeChart`` for code that can run before the catalogue is loaded
    /// (e.g. a view that degrades gracefully without type data).
    public static var loadedTypeChart: TypeChart? { state.withLock(\.typeChart) }

    /// All loaded moves, in no particular order. Empty until initialized.
    public static var allMoves: [Move] { state.withLock { Array($0.moves.values) } }

    /// Look up a single move by its API name (e.g. "thunderbolt").
    public static func move(named name: String) -> Move? {
        state.withLock { $0.moves[name] }
    }

    /// Load all moves and type data from cache or PokeAPI.
    ///
    /// Safe to call multiple times and from multiple tasks at once: after a
    /// successful load it's a no-op, and while a load is in flight later
    /// callers await that same load. If loading fails, the error is thrown
    /// to every waiting caller and the next call starts a fresh attempt.
    public static func initialize() async throws {
        let load: Task<Void, any Error>? = state.withLock { state in
            if state.isLoaded { return nil }
            if let inFlight = state.loading { return inFlight }
            let task = Task { try await loadAll() }
            state.loading = task
            return task
        }
        guard let load else { return }

        do {
            try await load.value
        } catch {
            // Only clear our own failed load: by the time this waiter
            // resumes, an earlier waiter may already have cleared it and a
            // new caller started a fresh attempt that mustn't be dropped.
            state.withLock { state in
                if state.loading == load { state.loading = nil }
            }
            throw error
        }
    }
}

// MARK: - Private

private extension PokeBattleKit {
    /// Load both catalogues, then publish them in a single locked write so
    /// readers never see a type chart without its moves (or vice versa).
    static func loadAll() async throws {
        let typeChart = try await loadTypeChart()
        let moves = try await loadMoves()
        let movesByName = Dictionary(uniqueKeysWithValues: moves.map { ($0.name, $0) })

        state.withLock { state in
            state.typeChart = typeChart
            state.moves = movesByName
            state.isLoaded = true
            state.loading = nil
        }
    }

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
