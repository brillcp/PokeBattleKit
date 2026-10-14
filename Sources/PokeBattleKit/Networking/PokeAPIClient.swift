import Foundation

/// Lightweight PokeAPI client using URLSession.
///
/// A stateless `Sendable` struct rather than an actor: it holds no mutable
/// state (`URLSession` is thread-safe), so the ~950 detail requests in
/// ``fetchMoves()`` download *and decode* in parallel across the task
/// group's child tasks instead of queueing behind one actor.
struct PokeAPIClient: Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://pokeapi.co/api/v2/")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchMoves() async throws -> [APIMoveResponse] {
        let url = buildURL(path: "move", query: ["limit": "2000"])
        let list: APIListResponse = try await fetch(url)
        return try await withThrowingTaskGroup(of: APIMoveResponse.self) { group in
            for item in list.results {
                group.addTask { try await fetch(buildURL(path: "move/\(item.name)")) }
            }
            var results: [APIMoveResponse] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    func fetchTypes() async throws -> [APITypeResponse] {
        let url = buildURL(path: "type", query: ["limit": "20"])
        let list: APIListResponse = try await fetch(url)
        let excluded: Set<String> = ["unknown", "shadow", "stellar"]
        let names = list.results.map(\.name).filter { !excluded.contains($0) }
        return try await withThrowingTaskGroup(of: APITypeResponse.self) { group in
            for name in names {
                group.addTask { try await fetch(buildURL(path: "type/\(name)")) }
            }
            var results: [APITypeResponse] = []
            for try await result in group { results.append(result) }
            return results
        }
    }
}

// MARK: - Private

private extension PokeAPIClient {
    func buildURL(path: String, query: [String: String] = [:]) -> URL {
        var url = baseURL.appendingPathComponent(path)
        if !query.isEmpty {
            url = url.appending(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        }
        return url
    }

    /// Nonisolated `async`, so in the package's Swift 6 mode it runs on the
    /// global concurrent executor: each child task decodes its own response.
    func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PokeAPIError.badResponse
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

/// Errors from PokeAPI requests.
public enum PokeAPIError: Error, Sendable {
    case badResponse
    case notInitialized
}
