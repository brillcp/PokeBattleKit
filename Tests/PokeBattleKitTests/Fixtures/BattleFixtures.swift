@testable import PokeBattleKit

/// Real-world fixtures for whole-battle tests: the full 18-type chart, a
/// cross-section of Pokémon with their actual base stats, and a catalogue of
/// moves with their PokeAPI data. Kept offline so the balance simulation is
/// reproducible and doesn't need the network.
enum Fixtures {

    // MARK: Type chart

    /// The Gen VI+ type chart.
    static let typeChart = TypeChart(attackers: [
        "normal": .init(doubleDamageTo: [], halfDamageTo: ["rock", "steel"], noDamageTo: ["ghost"]),
        "fire": .init(doubleDamageTo: ["grass", "ice", "bug", "steel"], halfDamageTo: ["fire", "water", "rock", "dragon"], noDamageTo: []),
        "water": .init(doubleDamageTo: ["fire", "ground", "rock"], halfDamageTo: ["water", "grass", "dragon"], noDamageTo: []),
        "electric": .init(doubleDamageTo: ["water", "flying"], halfDamageTo: ["electric", "grass", "dragon"], noDamageTo: ["ground"]),
        "grass": .init(doubleDamageTo: ["water", "ground", "rock"], halfDamageTo: ["fire", "grass", "poison", "flying", "bug", "dragon", "steel"], noDamageTo: []),
        "ice": .init(doubleDamageTo: ["grass", "ground", "flying", "dragon"], halfDamageTo: ["fire", "water", "ice", "steel"], noDamageTo: []),
        "fighting": .init(doubleDamageTo: ["normal", "ice", "rock", "dark", "steel"], halfDamageTo: ["poison", "flying", "psychic", "bug", "fairy"], noDamageTo: ["ghost"]),
        "poison": .init(doubleDamageTo: ["grass", "fairy"], halfDamageTo: ["poison", "ground", "rock", "ghost"], noDamageTo: ["steel"]),
        "ground": .init(doubleDamageTo: ["fire", "electric", "poison", "rock", "steel"], halfDamageTo: ["grass", "bug"], noDamageTo: ["flying"]),
        "flying": .init(doubleDamageTo: ["grass", "fighting", "bug"], halfDamageTo: ["electric", "rock", "steel"], noDamageTo: []),
        "psychic": .init(doubleDamageTo: ["fighting", "poison"], halfDamageTo: ["psychic", "steel"], noDamageTo: ["dark"]),
        "bug": .init(doubleDamageTo: ["grass", "psychic", "dark"], halfDamageTo: ["fire", "fighting", "poison", "flying", "ghost", "steel", "fairy"], noDamageTo: []),
        "rock": .init(doubleDamageTo: ["fire", "ice", "flying", "bug"], halfDamageTo: ["fighting", "ground", "steel"], noDamageTo: []),
        "ghost": .init(doubleDamageTo: ["psychic", "ghost"], halfDamageTo: ["dark"], noDamageTo: ["normal"]),
        "dragon": .init(doubleDamageTo: ["dragon"], halfDamageTo: ["steel"], noDamageTo: ["fairy"]),
        "dark": .init(doubleDamageTo: ["psychic", "ghost"], halfDamageTo: ["fighting", "dark", "fairy"], noDamageTo: []),
        "steel": .init(doubleDamageTo: ["ice", "rock", "fairy"], halfDamageTo: ["fire", "water", "electric", "steel"], noDamageTo: []),
        "fairy": .init(doubleDamageTo: ["fighting", "dragon", "dark"], halfDamageTo: ["fire", "poison", "steel"], noDamageTo: []),
    ])

    // MARK: Pokémon

    struct Species {
        let pokemon: TestPokemon
        let movepool: [String]
        var bst: Int { pokemon.statLookup.values.reduce(0, +) }
    }

    /// Base stats in the order HP / Atk / Def / SpA / SpD / Spe.
    static func species(
        _ id: Int, _ name: String, _ types: [String],
        _ s: (Int, Int, Int, Int, Int, Int),
        _ movepool: [String]
    ) -> Species {
        Species(
            pokemon: TestPokemon(
                id: id, name: name, frontSprite: "", backSprite: nil, typeNames: types,
                statLookup: [
                    "hp": s.0, "attack": s.1, "defense": s.2,
                    "special-attack": s.3, "special-defense": s.4, "speed": s.5
                ]
            ),
            movepool: movepool
        )
    }

    static let roster: [Species] = [
        species(25, "pikachu", ["electric"], (35, 55, 40, 50, 50, 90),
                ["thunderbolt", "thunder", "thunder-punch", "wild-charge", "quick-attack", "fake-out", "iron-tail", "surf", "thunder-wave", "agility", "nasty-plot", "double-team", "body-slam", "grass-knot"]),
        species(26, "raichu", ["electric"], (60, 90, 55, 90, 80, 110),
                ["thunderbolt", "thunder", "thunder-punch", "wild-charge", "focus-blast", "grass-knot", "surf", "fake-out", "thunder-wave", "nasty-plot", "agility", "brick-break", "quick-attack"]),
        species(6, "charizard", ["fire", "flying"], (78, 84, 78, 109, 85, 100),
                ["flamethrower", "fire-blast", "flare-blitz", "air-slash", "hurricane", "dragon-pulse", "dragon-claw", "earthquake", "focus-blast", "roost", "dragon-dance", "will-o-wisp", "solar-beam", "flame-charge", "shadow-claw"]),
        species(9, "blastoise", ["water"], (79, 83, 100, 85, 105, 78),
                ["surf", "hydro-pump", "waterfall", "aqua-jet", "ice-beam", "blizzard", "flash-cannon", "dark-pulse", "earthquake", "aura-sphere", "shell-smash", "iron-defense", "toxic", "rest", "rapid-spin"]),
        species(3, "venusaur", ["grass", "poison"], (80, 82, 83, 100, 100, 80),
                ["energy-ball", "giga-drain", "leaf-storm", "sludge-bomb", "earthquake", "seed-bomb", "bullet-seed", "synthesis", "sleep-powder", "leech-seed", "toxic", "swords-dance", "earth-power", "body-slam"]),
        species(94, "gengar", ["ghost", "poison"], (60, 65, 60, 130, 75, 110),
                ["shadow-ball", "sludge-bomb", "focus-blast", "thunderbolt", "dazzling-gleam", "energy-ball", "hypnosis", "will-o-wisp", "toxic", "nasty-plot", "confuse-ray", "dark-pulse", "shadow-claw"]),
        species(65, "alakazam", ["psychic"], (55, 50, 45, 135, 95, 120),
                ["psychic", "psyshock", "shadow-ball", "focus-blast", "dazzling-gleam", "energy-ball", "calm-mind", "recover", "thunder-wave", "hypnosis", "fire-punch", "ice-punch", "thunder-punch"]),
        species(68, "machamp", ["fighting"], (90, 130, 80, 65, 85, 55),
                ["close-combat", "dynamic-punch", "brick-break", "cross-chop", "bullet-punch", "stone-edge", "rock-slide", "earthquake", "ice-punch", "fire-punch", "thunder-punch", "knock-off", "bulk-up", "poison-jab", "mach-punch"]),
        species(130, "gyarados", ["water", "flying"], (95, 125, 79, 60, 100, 81),
                ["waterfall", "aqua-tail", "hydro-pump", "bounce", "earthquake", "ice-fang", "crunch", "stone-edge", "iron-head", "dragon-dance", "thunder-wave", "outrage", "body-slam", "hyper-beam"]),
        species(143, "snorlax", ["normal"], (160, 110, 65, 65, 110, 30),
                ["body-slam", "double-edge", "giga-impact", "hyper-beam", "earthquake", "crunch", "fire-punch", "ice-punch", "thunder-punch", "rest", "curse", "belly-drum", "heavy-slam", "seed-bomb"]),
        species(149, "dragonite", ["dragon", "flying"], (91, 134, 95, 100, 100, 80),
                ["outrage", "dragon-claw", "extreme-speed", "earthquake", "fire-punch", "ice-punch", "thunder-punch", "iron-head", "hurricane", "draco-meteor", "dragon-dance", "roost", "fire-blast", "thunder-wave"]),
        species(448, "lucario", ["fighting", "steel"], (70, 110, 70, 115, 70, 90),
                ["close-combat", "aura-sphere", "flash-cannon", "meteor-mash", "bullet-punch", "extreme-speed", "crunch", "ice-punch", "earthquake", "swords-dance", "nasty-plot", "dark-pulse", "dragon-pulse", "power-up-punch"]),
        species(445, "garchomp", ["dragon", "ground"], (108, 130, 95, 80, 85, 102),
                ["earthquake", "outrage", "dragon-claw", "stone-edge", "fire-fang", "iron-head", "poison-jab", "draco-meteor", "fire-blast", "swords-dance", "sand-attack", "earth-power", "rock-slide", "aqua-tail"]),
        species(248, "tyranitar", ["rock", "dark"], (100, 134, 110, 95, 100, 61),
                ["stone-edge", "rock-slide", "crunch", "earthquake", "ice-punch", "fire-punch", "thunder-punch", "iron-head", "dragon-dance", "fire-blast", "ice-beam", "dark-pulse", "superpower", "screech"]),
        species(700, "sylveon", ["fairy"], (95, 65, 65, 110, 130, 60),
                ["moonblast", "dazzling-gleam", "hyper-voice", "shadow-ball", "psyshock", "calm-mind", "wish", "protect", "quick-attack", "baby-doll-eyes", "draining-kiss", "yawn"]),
        species(212, "scizor", ["bug", "steel"], (70, 130, 100, 55, 80, 65),
                ["bullet-punch", "x-scissor", "iron-head", "u-turn", "close-combat", "superpower", "knock-off", "brick-break", "aerial-ace", "swords-dance", "roost", "agility", "night-slash", "quick-attack"]),
        species(135, "jolteon", ["electric"], (65, 65, 60, 110, 95, 130),
                ["thunderbolt", "thunder", "volt-switch", "shadow-ball", "signal-beam", "hyper-voice", "thunder-wave", "toxic", "agility", "double-kick", "pin-missile", "quick-attack"]),
        species(12, "butterfree", ["bug", "flying"], (60, 45, 50, 90, 80, 70),
                ["bug-buzz", "air-slash", "psychic", "energy-ball", "shadow-ball", "sleep-powder", "stun-spore", "quiver-dance", "giga-drain", "confusion", "gust", "u-turn"]),
        species(74, "geodude", ["rock", "ground"], (40, 80, 100, 30, 30, 20),
                ["rock-slide", "stone-edge", "earthquake", "rock-blast", "fire-punch", "thunder-punch", "double-edge", "defense-curl", "rock-polish", "self-destruct", "explosion", "brick-break"]),
        species(131, "lapras", ["water", "ice"], (130, 85, 80, 85, 95, 60),
                ["surf", "hydro-pump", "ice-beam", "blizzard", "freeze-dry", "thunderbolt", "psychic", "body-slam", "ice-shard", "icicle-spear", "sing", "confuse-ray", "rest", "dragon-dance"]),
        species(110, "weezing", ["poison"], (65, 90, 120, 85, 70, 60),
                ["sludge-bomb", "flamethrower", "fire-blast", "thunderbolt", "shadow-ball", "dark-pulse", "will-o-wisp", "toxic", "pain-split", "explosion", "dazzling-gleam", "gyro-ball"]),
        species(59, "arcanine", ["fire"], (90, 110, 80, 100, 80, 95),
                ["flare-blitz", "flamethrower", "fire-blast", "extreme-speed", "wild-charge", "crunch", "close-combat", "iron-head", "will-o-wisp", "morning-sun", "play-rough", "thunder-fang", "fire-fang"]),
        species(473, "mamoswine", ["ice", "ground"], (110, 130, 80, 70, 60, 80),
                ["earthquake", "icicle-crash", "ice-shard", "icicle-spear", "stone-edge", "rock-slide", "superpower", "knock-off", "freeze-dry", "earth-power", "ice-beam", "amnesia", "double-edge"]),
        species(468, "togekiss", ["fairy", "flying"], (85, 50, 95, 120, 115, 80),
                ["moonblast", "dazzling-gleam", "air-slash", "aura-sphere", "flamethrower", "shadow-ball", "roost", "nasty-plot", "thunder-wave", "extreme-speed", "psychic", "yawn"]),
    ]

    // MARK: Moves

    /// The catalogue every movepool name resolves against. Names that are
    /// missing here (Protect, Wish, Curse, ...) are moves the engine doesn't
    /// model and PokeAPI would report as having no power and no effect, so
    /// the loadout code never sees them either way.
    static let moves: [String: MoveSnapshot] = {
        let all: [MoveSnapshot] = [
            // Normal
            m("tackle", "normal", .physical, 40),
            m("body-slam", "normal", .physical, 85, ailment: "paralysis", ailmentChance: 30),
            m("double-edge", "normal", .physical, 120, drain: -33),
            m("hyper-beam", "normal", .special, 150, accuracy: 90),
            m("giga-impact", "normal", .physical, 150, accuracy: 90),
            m("quick-attack", "normal", .physical, 40, priority: 1),
            m("extreme-speed", "normal", .physical, 80, priority: 2),
            m("fake-out", "normal", .physical, 40, priority: 3, flinch: 100),
            m("hyper-voice", "normal", .special, 90),
            m("swords-dance", "normal", .status, stats: [("attack", 2)], target: "user"),
            m("growl", "normal", .status, stats: [("attack", -1)], target: "all-opponents"),
            m("screech", "normal", .status, accuracy: 85, stats: [("defense", -2)], target: "selected-pokemon"),
            m("double-team", "normal", .status, stats: [("evasion", 1)], target: "user"),
            m("defense-curl", "normal", .status, stats: [("defense", 1)], target: "user"),
            m("belly-drum", "normal", .status, stats: [("attack", 12)], target: "user"),
            m("shell-smash", "normal", .status, stats: [("attack", 2), ("special-attack", 2), ("speed", 2), ("defense", -1), ("special-defense", -1)], target: "user"),
            m("sing", "normal", .status, accuracy: 55, ailment: "sleep"),
            m("baby-doll-eyes", "fairy", .status, priority: 1, stats: [("attack", -1)], target: "selected-pokemon"),
            m("yawn", "normal", .status, ailment: "yawn"),
            m("self-destruct", "normal", .physical, 200),
            m("explosion", "normal", .physical, 250),
            m("rapid-spin", "normal", .physical, 50, stats: [("speed", 1)], effectChance: 100, category: "damage-raise"),
            m("pain-split", "normal", .status),
            // Fire
            m("flamethrower", "fire", .special, 90, ailment: "burn", ailmentChance: 10),
            m("fire-blast", "fire", .special, 110, accuracy: 85, ailment: "burn", ailmentChance: 10),
            m("flare-blitz", "fire", .physical, 120, ailment: "burn", ailmentChance: 10, drain: -33),
            m("fire-punch", "fire", .physical, 75, ailment: "burn", ailmentChance: 10),
            m("fire-fang", "fire", .physical, 65, accuracy: 95, ailment: "burn", ailmentChance: 10, flinch: 10),
            m("flame-charge", "fire", .physical, 50, stats: [("speed", 1)], effectChance: 100, category: "damage-raise"),
            m("will-o-wisp", "fire", .status, accuracy: 85, ailment: "burn"),
            // Water
            m("surf", "water", .special, 90),
            m("hydro-pump", "water", .special, 110, accuracy: 80),
            m("waterfall", "water", .physical, 80, flinch: 20),
            m("aqua-tail", "water", .physical, 90, accuracy: 90),
            m("aqua-jet", "water", .physical, 40, priority: 1),
            // Electric
            m("thunderbolt", "electric", .special, 90, ailment: "paralysis", ailmentChance: 10),
            m("thunder", "electric", .special, 110, accuracy: 70, ailment: "paralysis", ailmentChance: 30),
            m("thunder-punch", "electric", .physical, 75, ailment: "paralysis", ailmentChance: 10),
            m("thunder-fang", "electric", .physical, 65, accuracy: 95, ailment: "paralysis", ailmentChance: 10, flinch: 10),
            m("wild-charge", "electric", .physical, 90, drain: -25),
            m("volt-switch", "electric", .special, 70),
            m("thunder-wave", "electric", .status, accuracy: 90, ailment: "paralysis"),
            // Grass
            m("energy-ball", "grass", .special, 90, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("giga-drain", "grass", .special, 75, drain: 50),
            m("leaf-storm", "grass", .special, 130, accuracy: 90, stats: [("special-attack", -2)], category: "damage-raise"),
            m("seed-bomb", "grass", .physical, 80),
            m("bullet-seed", "grass", .physical, 25, hits: (2, 5)),
            m("grass-knot", "grass", .special, nil),
            m("solar-beam", "grass", .special, 120),
            m("synthesis", "grass", .status, healing: 50),
            m("sleep-powder", "grass", .status, accuracy: 75, ailment: "sleep"),
            m("stun-spore", "grass", .status, accuracy: 75, ailment: "paralysis"),
            m("leech-seed", "grass", .status, accuracy: 90, ailment: "leech-seed"),
            m("morning-sun", "normal", .status, healing: 50),
            // Ice
            m("ice-beam", "ice", .special, 90, ailment: "freeze", ailmentChance: 10),
            m("blizzard", "ice", .special, 110, accuracy: 70, ailment: "freeze", ailmentChance: 10),
            m("freeze-dry", "ice", .special, 70, ailment: "freeze", ailmentChance: 10),
            m("ice-punch", "ice", .physical, 75, ailment: "freeze", ailmentChance: 10),
            m("ice-fang", "ice", .physical, 65, accuracy: 95, ailment: "freeze", ailmentChance: 10, flinch: 10),
            m("ice-shard", "ice", .physical, 40, priority: 1),
            m("icicle-crash", "ice", .physical, 85, accuracy: 90, flinch: 30),
            m("icicle-spear", "ice", .physical, 25, hits: (2, 5)),
            m("amnesia", "psychic", .status, stats: [("special-defense", 2)], target: "user"),
            // Fighting
            m("close-combat", "fighting", .physical, 120, stats: [("defense", -1), ("special-defense", -1)], category: "damage-raise"),
            m("superpower", "fighting", .physical, 120, stats: [("attack", -1), ("defense", -1)], category: "damage-raise"),
            m("brick-break", "fighting", .physical, 75),
            m("cross-chop", "fighting", .physical, 100, accuracy: 80, critRate: 1),
            m("dynamic-punch", "fighting", .physical, 100, accuracy: 50, ailment: "confusion", ailmentChance: 100),
            m("aura-sphere", "fighting", .special, 80, accuracy: nil),
            m("focus-blast", "fighting", .special, 120, accuracy: 70, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("mach-punch", "fighting", .physical, 40, priority: 1),
            m("power-up-punch", "fighting", .physical, 40, stats: [("attack", 1)], effectChance: 100, category: "damage-raise"),
            m("double-kick", "fighting", .physical, 30, hits: (2, 2)),
            m("bulk-up", "fighting", .status, stats: [("attack", 1), ("defense", 1)], target: "user"),
            // Poison
            m("sludge-bomb", "poison", .special, 90, ailment: "poison", ailmentChance: 30),
            m("poison-jab", "poison", .physical, 80, ailment: "poison", ailmentChance: 30),
            m("toxic", "poison", .status, accuracy: 90, ailment: "bad-poison"),
            // Ground
            m("earthquake", "ground", .physical, 100),
            m("earth-power", "ground", .special, 90, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("sand-attack", "ground", .status, stats: [("accuracy", -1)], target: "selected-pokemon"),
            // Flying
            m("air-slash", "flying", .special, 75, accuracy: 95, flinch: 30),
            m("hurricane", "flying", .special, 110, accuracy: 70, ailment: "confusion", ailmentChance: 30),
            m("aerial-ace", "flying", .physical, 60, accuracy: nil),
            m("gust", "flying", .special, 40),
            m("bounce", "flying", .physical, 85, accuracy: 85, ailment: "paralysis", ailmentChance: 30),
            m("roost", "flying", .status, healing: 50),
            // Psychic
            m("psychic", "psychic", .special, 90, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("psyshock", "psychic", .special, 80),
            m("confusion", "psychic", .special, 50, ailment: "confusion", ailmentChance: 10),
            m("calm-mind", "psychic", .status, stats: [("special-attack", 1), ("special-defense", 1)], target: "user"),
            m("agility", "psychic", .status, stats: [("speed", 2)], target: "user"),
            m("rock-polish", "rock", .status, stats: [("speed", 2)], target: "user"),
            m("hypnosis", "psychic", .status, accuracy: 60, ailment: "sleep"),
            m("rest", "psychic", .status),
            m("recover", "normal", .status, healing: 50),
            // Bug
            m("bug-buzz", "bug", .special, 90, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("x-scissor", "bug", .physical, 80),
            m("u-turn", "bug", .physical, 70),
            m("signal-beam", "bug", .special, 75, ailment: "confusion", ailmentChance: 10),
            m("pin-missile", "bug", .physical, 25, accuracy: 95, hits: (2, 5)),
            m("quiver-dance", "bug", .status, stats: [("special-attack", 1), ("special-defense", 1), ("speed", 1)], target: "user"),
            // Rock
            m("stone-edge", "rock", .physical, 100, accuracy: 80, critRate: 1),
            m("rock-slide", "rock", .physical, 75, accuracy: 90, flinch: 30),
            m("rock-blast", "rock", .physical, 25, accuracy: 90, hits: (2, 5)),
            // Ghost
            m("shadow-ball", "ghost", .special, 80, stats: [("special-defense", -1)], effectChance: 20, category: "damage-lower"),
            m("shadow-claw", "ghost", .physical, 70, critRate: 1),
            m("confuse-ray", "ghost", .status, ailment: "confusion"),
            // Dragon
            m("outrage", "dragon", .physical, 120),
            m("dragon-claw", "dragon", .physical, 80),
            m("dragon-pulse", "dragon", .special, 85),
            m("draco-meteor", "dragon", .special, 130, accuracy: 90, stats: [("special-attack", -2)], category: "damage-raise"),
            m("dragon-dance", "dragon", .status, stats: [("attack", 1), ("speed", 1)], target: "user"),
            // Dark
            m("crunch", "dark", .physical, 80, stats: [("defense", -1)], effectChance: 20, category: "damage-lower"),
            m("dark-pulse", "dark", .special, 80, flinch: 20),
            m("knock-off", "dark", .physical, 65),
            m("night-slash", "dark", .physical, 70, critRate: 1),
            m("nasty-plot", "dark", .status, stats: [("special-attack", 2)], target: "user"),
            // Steel
            m("iron-head", "steel", .physical, 80, flinch: 30),
            m("iron-tail", "steel", .physical, 100, accuracy: 75, stats: [("defense", -1)], effectChance: 30, category: "damage-lower"),
            m("flash-cannon", "steel", .special, 80, stats: [("special-defense", -1)], effectChance: 10, category: "damage-lower"),
            m("meteor-mash", "steel", .physical, 90, accuracy: 90, stats: [("attack", 1)], effectChance: 20, category: "damage-raise"),
            m("bullet-punch", "steel", .physical, 40, priority: 1),
            m("heavy-slam", "steel", .physical, nil),
            m("gyro-ball", "steel", .physical, nil),
            m("iron-defense", "steel", .status, stats: [("defense", 2)], target: "user"),
            // Fairy
            m("moonblast", "fairy", .special, 95, stats: [("special-attack", -1)], effectChance: 30, category: "damage-lower"),
            m("dazzling-gleam", "fairy", .special, 80),
            m("play-rough", "fairy", .physical, 90, accuracy: 90, stats: [("attack", -1)], effectChance: 10, category: "damage-lower"),
            m("draining-kiss", "fairy", .special, 50, drain: 75),
        ]
        return Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
    }()

    /// The species' movepool resolved against ``moves`` and filtered the way
    /// the app filters PokeAPI moves before building a loadout.
    static func battleReadyMoves(for species: Species) -> [MoveSnapshot] {
        species.movepool.compactMap { moves[$0] }.filter(\.isBattleReady)
    }

    /// Builds a move from its PokeAPI fields. `category` is PokeAPI's
    /// `meta.category`, `target` its move `target`; together they say who
    /// a move's stat changes apply to.
    static func m(
        _ name: String,
        _ type: String,
        _ damageClass: DamageClass,
        _ power: Int? = nil,
        accuracy: Int? = 100,
        priority: Int = 0,
        ailment: String = "none",
        ailmentChance: Int = 0,
        drain: Int = 0,
        healing: Int = 0,
        stats: [(String, Int)] = [],
        effectChance: Int? = nil,
        category: String? = nil,
        target: String = "selected-pokemon",
        hits: (Int, Int)? = nil,
        critRate: Int = 0,
        flinch: Int = 0
    ) -> MoveSnapshot {
        MoveSnapshot(
            name: name,
            displayName: name.replacingOccurrences(of: "-", with: " ").capitalized,
            power: power,
            accuracy: damageClass == .status && accuracy == 100 ? nil : accuracy,
            priority: priority,
            damageClass: damageClass.rawValue,
            typeName: type,
            ailment: ailment,
            ailmentChance: ailmentChance,
            drain: drain,
            healing: healing,
            effectChance: effectChance,
            statChangeNames: stats.map(\.0),
            statChangeDeltas: stats.map(\.1),
            isRechargeMove: MoveClassification.rechargeMoves.contains(name),
            hasSelfDebuff: MoveClassification.selfDebuffMoves.contains(name),
            statChangeTarget: statChangeTarget(stats: stats, category: category, target: target),
            minHits: hits?.0,
            maxHits: hits?.1,
            critRate: critRate,
            flinchChance: flinch
        )
    }

    /// Mirrors ``Move/statChangeTarget``. `category` uses PokeAPI's real
    /// spelling ("damage-raise").
    static func statChangeTarget(stats: [(String, Int)], category: String?, target: String) -> StatChangeTarget? {
        guard !stats.isEmpty else { return nil }
        switch category {
        case "damage-raise": return .user
        case "damage-lower": return .opponent
        default: return MoveClassification.userTargets.contains(target) ? .user : .opponent
        }
    }
}
