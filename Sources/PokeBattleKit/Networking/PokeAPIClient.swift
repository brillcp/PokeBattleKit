import Foundation

/// Lightweight PokeAPI client using URLSession.
actor PokeAPIClient {
    private let session: URLSession
    private let baseURL = URL(string: "https://pokeapi.co/api/v2/")!
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchMoves() async throws -> [APIMoveResponse] {
        let url = buildURL(path: "move", query: ["limit": "2000"])
        let list: APIListResponse = try await fetch(url)
        return try await withThrowingTaskGroup(of: APIMoveResponse.self) { group in
            for item in list.results {
                group.addTask { try await self.fetch(self.buildURL(path: "move/\(item.name)")) }
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
                group.addTask { try await self.fetch(self.buildURL(path: "type/\(name)")) }
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

    func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PokeAPIError.badResponse
        }
        return try decoder.decode(T.self, from: data)
    }
}

/// Errors from PokeAPI requests.
public enum PokeAPIError: Error, Sendable {
    case badResponse
    case notInitialized
}
