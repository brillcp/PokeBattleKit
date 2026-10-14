import Foundation

/// Immutable Sendable snapshot of the full type damage relations chart.
///
/// Normally obtained from ``PokeBattleKit/typeChart`` after
/// ``PokeBattleKit/initialize()``, which builds it from PokeAPI's 18 battle
/// types. Tests and previews can build one directly with
/// ``init(attackers:)``.
public struct TypeChart: TypeEffectivenessProviding, Codable, Sendable {
    /// Damage relations keyed by attacking type name ("fire", "water", ...).
    public let attackers: [String: TypeMatchup]

    public init(attackers: [String: TypeMatchup]) {
        self.attackers = attackers
    }

    /// Product of the attacking type's multiplier against each defending
    /// type, e.g. Ground vs Fire/Flying is 2 x 0 = 0, Fire vs Grass/Bug is
    /// 2 x 2 = 4. An attacking type missing from the chart is neutral (1.0).
    public func multiplier(attacking: String, defenders: [String]) -> Double {
        attackers[attacking]?.effectiveness(against: defenders) ?? 1.0
    }
}

// MARK: - Internal

extension TypeChart {
    /// Builds the chart from the attacking side of each type's relations
    /// (the `*_damage_to` lists); the `*_from` lists are the same data
    /// viewed from the defender and aren't needed.
    init(from responses: [APITypeResponse]) {
        var dict: [String: TypeMatchup] = [:]
        for response in responses {
            let relations = response.damageRelations
            dict[response.name] = TypeMatchup(
                doubleDamageTo: relations.doubleDamageTo.map(\.name),
                halfDamageTo: relations.halfDamageTo.map(\.name),
                noDamageTo: relations.noDamageTo.map(\.name)
            )
        }
        self.init(attackers: dict)
    }
}

/// One attacking type's damage relations. Defending types listed in none
/// of the arrays take neutral (1x) damage.
public struct TypeMatchup: Codable, Sendable {
    public let doubleDamageTo: [String]
    public let halfDamageTo: [String]
    public let noDamageTo: [String]

    public init(doubleDamageTo: [String], halfDamageTo: [String], noDamageTo: [String]) {
        self.doubleDamageTo = doubleDamageTo
        self.halfDamageTo = halfDamageTo
        self.noDamageTo = noDamageTo
    }
}

// MARK: - Internal

extension TypeMatchup {
    /// Multiplies 2, 0.5 or 1 per defending type. An immunity returns 0
    /// outright, which also zeroes everything after it in the fold.
    func effectiveness(against defenderTypeNames: [String]) -> Double {
        defenderTypeNames.reduce(1.0) { product, defender in
            if noDamageTo.contains(defender) { return 0 }
            if doubleDamageTo.contains(defender) { return product * 2 }
            if halfDamageTo.contains(defender) { return product * 0.5 }
            return product
        }
    }
}
