/// Learnset rules for alternate forms.
///
/// PokeAPI lists Mega, G-Max, Totem and other forms as separate Pokémon,
/// and many of them have a tiny or empty learnset there. In the games a
/// form battles with its base species' moves, so a form with fewer than
/// ``minimumOwnMoves`` battle-ready moves should also get its base
/// species' moves. ``baseNames(of:)`` gives the names to look up.
public enum PokemonForms {
    /// A form with fewer battle-ready moves than this borrows its base
    /// species' learnset (four fills a loadout).
    public static let minimumOwnMoves = 4

    /// Candidate base species names for a PokeAPI Pokémon name, most
    /// specific first: "charizard-mega-x" gives ["charizard-mega",
    /// "charizard"]. Use the first one that exists and has a learnset.
    /// Some species' default form has a suffix in PokeAPI ("zygarde-50",
    /// "giratina-altered"), so when no candidate exists as is, look for a
    /// Pokémon whose name starts with a candidate followed by "-".
    public static func baseNames(of name: String) -> [String] {
        var parts = name.lowercased().split(separator: "-").map(String.init)
        var names: [String] = []
        while parts.count > 1 {
            parts.removeLast()
            names.append(parts.joined(separator: "-"))
        }
        return names
    }
}
