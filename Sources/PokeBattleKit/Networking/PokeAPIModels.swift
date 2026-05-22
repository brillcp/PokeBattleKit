import Foundation

/// PokeAPI list envelope (e.g. `/move?limit=2000`).
struct APIListResponse: Decodable, Sendable {
    let results: [APIListItem]
}

/// Single item in a PokeAPI list response.
struct APIListItem: Decodable, Sendable {
    let name: String
    let url: String
}

/// Raw PokeAPI `/move/{name}` response.
struct APIMoveResponse: Decodable, Sendable {
    let name: String
    let power: Int?
    let accuracy: Int?
    let pp: Int?
    let priority: Int
    let damageClass: NamedRef
    let type: NamedRef
    let meta: Meta?
    let statChanges: [StatChange]
    let effectChance: Int?

    struct Meta: Decodable, Sendable {
        let ailment: NamedRef
        let ailmentChance: Int
        let drain: Int
        let healing: Int
        let category: NamedRef
    }

    struct StatChange: Decodable, Sendable {
        let change: Int
        let stat: NamedRef
    }
}

/// Raw PokeAPI `/type/{name}` response.
struct APITypeResponse: Decodable, Sendable {
    let name: String
    let damageRelations: DamageRelations

    struct DamageRelations: Decodable, Sendable {
        let doubleDamageTo: [NamedRef]
        let doubleDamageFrom: [NamedRef]
        let halfDamageTo: [NamedRef]
        let halfDamageFrom: [NamedRef]
        let noDamageTo: [NamedRef]
        let noDamageFrom: [NamedRef]
    }
}

/// Reusable `{ "name": "..." }` reference in PokeAPI.
struct NamedRef: Decodable, Sendable {
    let name: String
}
