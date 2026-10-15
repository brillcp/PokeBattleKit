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
        "headlong-rush", "clanging-scales", "shell-smash", "armor-cannon",
        "spin-out", "make-it-rain"
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
        "shadow-force", "geomancy", "meteor-beam", "electro-shot"
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

    /// Moves that only work on the user's first turn in battle.
    public static let firstTurnOnlyMoves: Set<String> = [
        "fake-out", "first-impression", "mat-block"
    ]

    /// Moves that fail unless the target is asleep.
    public static let requiresSleepingTarget: Set<String> = [
        "dream-eater", "nightmare"
    ]

    /// Moves whose mechanics the engine can't resolve faithfully (they
    /// depend on held items, earlier turns, the opponent's choice, allies,
    /// or other state the engine doesn't track), moves that need an ally
    /// or a gender the engine doesn't have (Aromatic Mist, Captivate), plus
    /// moves that help the opponent as much as the user. ``MoveData/isBattleReady`` drops them.
    public static let unsupportedMoves: Set<String> = [
        "aromatic-mist", "belch", "beat-up", "belly-drum", "bide", "burn-up",
        "captivate", "clangorous-soul", "counter", "decorate", "doom-desire",
        "double-shock", "fillet-away", "final-gambit", "fissure", "flatter", "fling",
        "flower-shield",
        "guillotine", "horn-drill", "metal-burst", "mirror-coat", "natural-gift",
        "sheer-cold", "silk-trap", "trump-card", "future-sight", "last-resort", "poltergeist", "present",
        "sleep-talk", "snore", "spit-up", "steel-roller",
        "sucker-punch", "swagger", "synchronoise", "thunderclap", "upper-hand"
    ]

    /// Moves that inflict bad poison (Toxic's escalating poison). PokeAPI
    /// reports their ailment as plain "poison", so they're named here.
    public static let badPoisonMoves: Set<String> = [
        "toxic", "poison-fang", "malignant-chain"
    ]

    /// Damaging moves whose power is worked out from the situation (weight,
    /// HP, Speed, stat stages, status, turn order) rather than fixed; see
    /// ``DamageCalculator/power(of:attacker:defender:context:randomized:)``.
    /// Those with no PokeAPI power at all are only damaging because of this.
    public static let computedPowerMoves: Set<String> = [
        "return", "frustration", "pika-papow", "veevee-volley",
        "low-kick", "grass-knot", "heavy-slam", "heat-crash",
        "reversal", "flail", "gyro-ball", "electro-ball",
        "hard-press", "wring-out", "crush-grip", "punishment",
        "stored-power", "power-trip", "magnitude",
        "facade", "hex", "venoshock", "brine", "acrobatics",
        "avalanche", "revenge", "payback", "bolt-beak", "fishious-rend", "assurance"
    ]

    /// Moves that deal a set amount of HP instead of using the damage
    /// formula; see ``DamageCalculator/power(of:attacker:defender:context:randomized:)``.
    public static let fixedDamageMoves: Set<String> = [
        "seismic-toss", "night-shade", "psywave", "dragon-rage", "sonic-boom",
        "super-fang", "natures-madness", "ruination", "endeavor"
    ]

    /// Moves that hit with the target's Attack (Foul Play).
    public static let usesTargetAttack: Set<String> = ["foul-play"]
    /// Moves that hit with the user's Defense (Body Press).
    public static let usesUserDefense: Set<String> = ["body-press"]
    /// Special moves that hit the target's Defense instead of Special
    /// Defense (Psyshock).
    public static let targetsPhysicalDefense: Set<String> = ["psyshock", "psystrike", "secret-sword"]

    /// Multi-hit moves whose power rises with each hit: Triple Axel is
    /// 20, 40, then 60.
    public static let escalatingMultiHitMoves: Set<String> = [
        "triple-axel", "triple-kick"
    ]

    /// Moves with a special mechanic the engine simplifies, and how. These
    /// stay in movepools because their main effect is modeled. Beyond this
    /// list, two simplifications apply to every move: secondary effects the
    /// engine doesn't model (confusion, trapping, ...) are ignored, and so
    /// are switching, field and lock-in effects.
    public static let approximations: [String: String] = [
        "stockpile": "only its Defense and Special Defense boost",
        "strength-sap": "only its Attack drop, not the heal",
        "syrup-bomb": "a one-off Speed drop instead of three turns of drops",
        "tar-shot": "only its Speed drop, not the Fire weakness",
        "toxic-thread": "only its Speed drop",
        "jungle-healing": "a heal for the user only",
        "purify": "a heal for the user only",
    ]

    /// Stats with stat stages the engine applies. Accuracy and evasion
    /// aren't modeled.
    public static let modeledStats: Set<String> = [
        "attack", "defense", "special-attack", "special-defense", "speed"
    ]

    /// PokeAPI move targets that mean the move affects its user.
    static let userTargets: Set<String> = [
        "user", "user-or-ally", "user-and-allies", "users-field", "all-allies"
    ]
}
