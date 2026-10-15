/// Moves that behave differently depending on which Pokémon uses them.
///
/// PokeAPI describes a move the same way for every user, but some moves are
/// tied to a species or form: Ivy Cudgel takes the type of Ogerpon's mask,
/// Raging Bull the type of Paldean Tauros's breed, and Tera Blast only
/// lowers its user's stats when Terapagos uses it in its Stellar Form. The
/// engine and the AI resolve every move through ``resolve(_:for:)`` before
/// using it, so these rules apply to the actual user in both.
///
/// Users are matched by PokeAPI Pokémon name (e.g. "ogerpon-wellspring-mask"),
/// case-insensitively.
public enum SpeciesMoveRules {

    /// `move` as it behaves when `user` uses it. Moves without a species
    /// rule come back unchanged.
    public static func resolve(_ move: some MoveData, for user: Combatant) -> MoveSnapshot {
        let snapshot = MoveSnapshot(from: move)
        let species = user.name.lowercased().replacingOccurrences(of: " ", with: "-")
        switch move.name {
        case "tera-blast":
            // The stat drops are part of Stellar Tera Blast, which only
            // Terapagos in its Stellar Form uses; anyone else's Tera Blast
            // is a plain attack.
            return species == "terapagos-stellar"
                ? snapshot.with(statChangeTarget: .user)
                : snapshot.with(statChangeNames: [], statChangeDeltas: [])
        case "ivy-cudgel":
            return snapshot.with(typeName: formType(species, [
                "wellspring": "water", "hearthflame": "fire", "cornerstone": "rock"
            ]) ?? "grass")
        case "raging-bull":
            return snapshot.with(typeName: formType(species, [
                "combat-breed": "fighting", "blaze-breed": "fire", "aqua-breed": "water"
            ]) ?? "normal")
        case "struggle":
            // Struggle is typeless in the games: no STAB, no weakness, and
            // nothing is immune to it.
            return snapshot.with(typeName: "typeless")
        case "aura-wheel":
            return snapshot.with(typeName: species.hasSuffix("hangry") ? "dark" : "electric")
        case "revelation-dance", "judgment", "multi-attack":
            // These take the user's own type (Oricorio's style, Arceus's
            // plate, Silvally's memory), which its form's types reflect.
            return snapshot.with(typeName: user.typeNames.first ?? snapshot.typeName)
        default:
            return snapshot
        }
    }

    /// The type for the first form keyword `species` contains.
    private static func formType(_ species: String, _ types: [String: String]) -> String? {
        types.first { species.contains($0.key) }?.value
    }
}

public extension MoveData {
    /// This move as it behaves when `user` uses it (see ``SpeciesMoveRules``).
    func resolved(for user: Combatant) -> MoveSnapshot {
        SpeciesMoveRules.resolve(self, for: user)
    }
}

extension MoveSnapshot {
    /// A copy with the given fields replaced.
    func with(
        typeName: String? = nil,
        statChangeNames: [String]? = nil,
        statChangeDeltas: [Int]? = nil,
        statChangeTarget: StatChangeTarget? = nil
    ) -> MoveSnapshot {
        MoveSnapshot(
            name: name, displayName: displayName, power: power, accuracy: accuracy,
            priority: priority, damageClass: damageClass, typeName: typeName ?? self.typeName,
            ailment: ailment, ailmentChance: ailmentChance, drain: drain, healing: healing,
            effectChance: effectChance,
            statChangeNames: statChangeNames ?? self.statChangeNames,
            statChangeDeltas: statChangeDeltas ?? self.statChangeDeltas,
            isRechargeMove: isRechargeMove, hasSelfDebuff: hasSelfDebuff,
            statChangeTarget: statChangeTarget ?? self.statChangeTarget,
            minHits: minHits, maxHits: maxHits, critRate: critRate, flinchChance: flinchChance
        )
    }
}
