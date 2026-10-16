import Foundation

/// How strong each Pokémon actually is in battle under this package's
/// rules, as an Elo-style rating (1500 is average; 400 points apart means
/// 10-to-1 odds).
///
/// Base stat total (BST) is a poor guide on its own: it ignores movepools,
/// so a Pokémon with big stats and no good attacks looks stronger than it
/// is. These ratings come from simulated battles instead: every Pokémon
/// fights many randomly drawn opponents at equal level with the package's
/// own AI (``BattleSimulator``), and the results are fitted to ratings
/// (a Bradley-Terry model). They ship as `strength-ratings.json`, and are
/// regenerated after rule or AI changes:
/// `GENERATE_RATINGS=1 swift test -c release -Xswiftc -enable-testing --filter generateStrengthRatings`.
///
/// Pokémon missing from the table (new ones) get an estimate from their BST
/// using a fit over the rated ones.
public enum PokemonStrength {

    /// The rating of the Pokémon with PokeAPI name `name`, or an estimate
    /// from `baseStatTotal` if it isn't in the table.
    public static func rating(forPokemonNamed name: String, baseStatTotal: Int) -> Double {
        table.ratings[name.lowercased()] ?? table.fit.intercept + table.fit.slope * Double(baseStatTotal)
    }

    /// Whether `name` has a simulated rating (rather than a BST estimate).
    public static func isRated(_ name: String) -> Bool {
        table.ratings[name.lowercased()] != nil
    }

    /// Predicted chance that a Pokémon rated `rating` beats one rated
    /// `opponent` (the Elo curve).
    public static func winChance(rating: Double, against opponent: Double) -> Double {
        1 / (1 + pow(10, (opponent - rating) / 400))
    }

    /// The ratings file's contents.
    public struct Table: Codable, Sendable {
        /// Linear estimate `intercept + slope * BST`, for unrated Pokémon.
        public struct Fit: Codable, Sendable {
            public let intercept: Double
            public let slope: Double
        }
        /// How the ratings were made, for reference.
        public let method: String
        public let fit: Fit
        /// PokeAPI name to rating.
        public let ratings: [String: Double]
    }

    static let table: Table = {
        guard let url = Bundle.module.url(forResource: "strength-ratings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data)
        else {
            // The table ships with the package, so this is a packaging bug.
            assertionFailure("strength-ratings.json is missing from the bundle or failed to decode")
            // No table: every Pokémon is estimated from BST with a neutral fit.
            return Table(method: "none", fit: .init(intercept: 1500 - 500 * 2, slope: 2), ratings: [:])
        }
        return table
    }()
}
