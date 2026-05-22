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

    func fetchMoveNames() async throws -> [String] {
        let url = buildURL(path: "move", query: ["limit": "2000"])
        let response: APIListResponse = try await fetch(url)
        return response.results.map(\.name)
    }

    func fetchMove(named name: String) async throws -> APIMoveResponse {
        try await fetch(buildURL(path: "move/\(name)"))
    }

    func fetchMoves(named names: [String], chunkSize: Int = 25) async throws -> [APIMoveResponse] {
        var results: [APIMoveResponse] = []
        results.reserveCapacity(names.count)

        for chunkStart in stride(from: 0, to: names.count, by: chunkSize) {
            let chunk = Array(names[chunkStart..<min(chunkStart + chunkSize, names.count)])
            let chunkResults = try await withThrowingTaskGroup(of: APIMoveResponse.self) { group in
                for name in chunk {
                    group.addTask { try await self.fetchMove(named: name) }
                }
                var collected: [APIMoveResponse] = []
                for try await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: chunkResults)
        }
        return results
    }

    func fetchTypeNames() async throws -> [String] {
        let url = buildURL(path: "type", query: ["limit": "20"])
        let response: APIListResponse = try await fetch(url)
        let excluded: Set<String> = ["unknown", "shadow", "stellar"]
        return response.results.map(\.name).filter { !excluded.contains($0) }
    }

    func fetchType(named name: String) async throws -> APITypeResponse {
        try await fetch(buildURL(path: "type/\(name)"))
    }

    func fetchTypes() async throws -> [APITypeResponse] {
        let names = try await fetchTypeNames()
        return try await withThrowingTaskGroup(of: APITypeResponse.self) { group in
            for name in names {
                group.addTask { try await self.fetchType(named: name) }
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
