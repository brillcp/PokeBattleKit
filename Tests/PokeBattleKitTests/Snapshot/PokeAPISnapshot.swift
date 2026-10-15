import Foundation
@testable import PokeBattleKit

/// A Pokémon from the offline PokeAPI snapshot.
struct SnapshotPokemon: PokemonData, Decodable, Sendable {
    let id: Int
    let name: String
    let weight: Int?
    let types: [String]
    let stats: [String: Int]
    /// Every move it can learn, by PokeAPI name.
    let moves: [String]

    var frontSprite: String { "" }
    var backSprite: String? { nil }
    var typeNames: [String] { types }
    var statLookup: [String: Int] { stats }
    var weightInHectograms: Int? { weight }
    var baseStatTotal: Int { stats.values.reduce(0, +) }
}

/// The offline PokeAPI snapshot in `Resources/pokeapi-snapshot.json`: every
/// move and every Pokémon. Refresh it with
/// `python3 Scripts/fetch_pokeapi_snapshot.py`.
///
/// Moves are decoded through the package's own `APIMoveResponse` and
/// `Move(from:)`, exactly like `PokeBattleKit.initialize()`, so tests see the
/// data the app sees.
enum PokeAPISnapshot {
    private struct File: Decodable {
        let moves: [APIMoveResponse]
        let pokemon: [SnapshotPokemon]
    }

    static let raw: [APIMoveResponse] = file.moves
    static let pokemon: [SnapshotPokemon] = file.pokemon
    static let moves: [String: Move] = Dictionary(
        uniqueKeysWithValues: file.moves.map { (Move(from: $0).name, Move(from: $0)) }
    )
    /// Moves at least one Pokémon can learn; the rest never reach a battle.
    static let learnableMoveNames: Set<String> = Set(file.pokemon.flatMap(\.moves))

    /// `pokemon`'s battle-ready moves, as the app filters them. A form
    /// with fewer than four (many Mega and G-Max forms have tiny learnsets
    /// in PokeAPI) also gets its base species' moves, as forms do in the
    /// games.
    static func battleReadyMoves(for pokemon: SnapshotPokemon) -> [MoveSnapshot] {
        func ready(_ names: [String]) -> [String] { names.filter { moves[$0]?.isBattleReady == true } }
        var names = ready(pokemon.moves)
        if names.count < PokemonForms.minimumOwnMoves, let base = baseForm(of: pokemon) {
            names = Array(Set(names).union(ready(base.moves))).sorted()
        }
        return names.compactMap { moves[$0] }.map { MoveSnapshot(from: $0) }
    }

    /// The form's base species, per ``PokemonForms/baseNames(of:)``.
    static func baseForm(of pokemon: SnapshotPokemon) -> SnapshotPokemon? {
        let candidates = PokemonForms.baseNames(of: pokemon.name)
        if let exact = candidates.lazy.compactMap({ byName[$0] }).first(where: { !$0.moves.isEmpty }) { return exact }
        for candidate in candidates {
            if let suffixed = file.pokemon.first(where: { $0.name.hasPrefix(candidate + "-") && $0.name != pokemon.name && !$0.moves.isEmpty }) {
                return suffixed
            }
        }
        return nil
    }

    static let byName: [String: SnapshotPokemon] = Dictionary(
        file.pokemon.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first }
    )

    private static let file: File = {
        guard let url = Bundle.module.url(forResource: "pokeapi-snapshot", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { fatalError("Missing pokeapi-snapshot.json; run Scripts/fetch_pokeapi_snapshot.py") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(File.self, from: data)
        } catch {
            fatalError("pokeapi-snapshot.json doesn't decode: \(error)")
        }
    }()
}
