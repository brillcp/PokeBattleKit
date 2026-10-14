import Foundation

/// Canonical move-name sets for classification.
///
/// PokeAPI doesn't expose these behaviors as structured fields, so they're
/// kept as hand-maintained lists of PokeAPI move names. ``Move`` derives
/// ``MoveData/isRechargeMove`` and ``MoveData/hasSelfDebuff`` from them, and
/// ``MoveData/isBattleReady`` uses them to exclude moves the engine can't
/// model.
public enum MoveClassification {
    /// Moves whose stat drops always hit the *user* (Overheat, Close
    /// Combat), plus Shell Smash, whose raises and drops are all on the
    /// user. The engine applies these stat changes unconditionally and to
    /// the user only, and the AI penalizes the damaging ones.
    public static let selfDebuffMoves: Set<String> = [
        "leaf-storm", "overheat", "draco-meteor", "fleur-cannon", "psycho-boost",
        "close-combat", "superpower", "v-create", "hammer-arm", "ice-hammer",
        "headlong-rush", "clanging-scales", "shell-smash"
    ]

    /// Moves that force the user to skip its next action after hitting.
    public static let rechargeMoves: Set<String> = [
        "blast-burn", "frenzy-plant", "giga-impact", "hydro-cannon",
        "hyper-beam", "meteor-assault", "prismatic-laser",
        "roar-of-time", "rock-wrecker"
    ]

    /// Two-turn moves (charge, or go semi-invulnerable, then strike). The
    /// engine has no multi-turn state for these, so they're excluded from
    /// loadouts rather than resolved as one-turn moves.
    public static let chargingMoves: Set<String> = [
        "sky-attack", "solar-beam", "solar-blade", "skull-bash",
        "razor-wind", "fly", "dig", "dive", "bounce", "phantom-force",
        "shadow-force", "geomancy", "meteor-beam"
    ]

    /// Moves that make the user faint. Not modeled by the engine and
    /// pointless in a one-on-one battle, so they're excluded from loadouts.
    public static let selfKOMoves: Set<String> = [
        "explosion", "self-destruct", "memento", "healing-wish",
        "lunar-dance", "final-gambit", "misty-explosion"
    ]

    /// Moves that fail entirely when the target is not poisoned. Used by
    /// the engine to no-op the effect (emitting a "no effect" event) and by
    /// AI scoring to refuse picking the move outside its precondition.
    public static let requiresPoisonedTarget: Set<String> = [
        "venom-drench"
    ]

    /// Status moves that fail against a type immune to the move's own type
    /// (Thunder Wave vs Ground). Most status moves ignore type matchups
    /// (Hypnosis still works on Dark types), so this is an explicit list.
    public static let respectsTypeImmunity: Set<String> = [
        "thunder-wave"
    ]
}
