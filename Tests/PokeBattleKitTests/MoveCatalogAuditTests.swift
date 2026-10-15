import Testing
@testable import PokeBattleKit

/// Audits every move in the PokeAPI snapshot against the engine, so a move
/// the engine misreads or a mechanic nobody decided about fails here instead
/// of showing up in some battle.
///
/// The rule: every PokeAPI value the engine reads must be one it knows, and
/// every learnable move with something unusual about it must be explicitly
/// modeled, approximated (``MoveClassification/approximations``) or
/// excluded. When PokeAPI adds a move or a value, the matching test fails
/// and names it.
@Suite("Move catalogue audit")
struct MoveCatalogAuditTests {

    // MARK: Values the engine knows

    static let knownCategories: Set<String> = [
        "damage", "damage-ailment", "damage-lower", "damage-raise", "damage-heal",
        "ailment", "net-good-stats", "heal", "swagger", "unique", "ohko",
        "field-effect", "whole-field-effect", "force-switch", Move.unknownCategory,
    ]
    /// Ailments the engine applies.
    static let modeledAilments: Set<String> = ["paralysis", "burn", "poison", "sleep", "freeze"]
    /// Ailments the engine deliberately ignores (the rest of the move still
    /// works).
    static let ignoredAilments: Set<String> = [
        "none", "confusion", "trap", "unknown", "no-type-immunity", "protect", "leech-seed",
        "infatuation", "disable", "embargo", "heal-block", "ingrain", "nightmare",
        "perish-song", "tar-shot", "silence", "torment", "yawn",
    ]
    static let knownTargets: Set<String> = [
        "selected-pokemon", "selected-pokemon-me-first", "user", "all-opponents",
        "all-other-pokemon", "random-opponent", "entire-field", "users-field",
        "opponents-field", "user-and-allies", "user-or-ally", "ally", "all-allies",
        "all-pokemon", "specific-move", "fainting-pokemon",
    ]
    static let knownStats: Set<String> = MoveClassification.modeledStats.union(["accuracy", "evasion"])
    static let unusualCategories: Set<String> = [
        "unique", "swagger", "ohko", "field-effect", "whole-field-effect", "force-switch",
    ]

    /// Learnable moves PokeAPI has no meta data for, whose stat changes the
    /// engine resolves by rule rather than data. Each was checked against
    /// the games; a new one fails `unknownCategoryMovesReviewed` until it's
    /// added here.
    static let reviewedUnknownCategoryTargets: [String: StatChangeTarget] = [
        "aqua-step": .user, "armor-cannon": .user, "chilling-water": .opponent,
        "electro-shot": .user, "fillet-away": .user, "lumina-crash": .opponent,
        "make-it-rain": .user, "pounce": .opponent, "silk-trap": .user,
        "spicy-extract": .opponent, "spin-out": .user, "tera-blast": .opponent,
        "tidy-up": .user, "torch-song": .user, "trailblaze": .user,
    ]

    static var learnable: [Move] {
        PokeAPISnapshot.moves.values
            .filter { PokeAPISnapshot.learnableMoveNames.contains($0.name) }
            .sorted { $0.name < $1.name }
    }

    // MARK: Tests

    @Test("Every learnset move exists in the move catalogue")
    func learnsetsResolve() {
        let missing = PokeAPISnapshot.learnableMoveNames.subtracting(PokeAPISnapshot.moves.keys)
        #expect(missing.isEmpty, "Unknown moves in learnsets: \(missing.sorted())")
    }

    @Test("Every PokeAPI value the engine reads is one it knows")
    func valuesAreKnown() {
        var unknown: [String] = []
        for raw in PokeAPISnapshot.raw {
            let category = raw.meta?.category.name ?? Move.unknownCategory
            if !Self.knownCategories.contains(category) { unknown.append("\(raw.name): category \(category)") }
            let ailment = raw.meta?.ailment.name ?? "none"
            if !Self.modeledAilments.contains(ailment), !Self.ignoredAilments.contains(ailment) {
                unknown.append("\(raw.name): ailment \(ailment)")
            }
            if let target = raw.target?.name, !Self.knownTargets.contains(target) {
                unknown.append("\(raw.name): target \(target)")
            }
            for change in raw.statChanges where !Self.knownStats.contains(change.stat.name) {
                unknown.append("\(raw.name): stat \(change.stat.name)")
            }
            if !["physical", "special", "status"].contains(raw.damageClass.name) {
                unknown.append("\(raw.name): damage class \(raw.damageClass.name)")
            }
        }
        #expect(unknown.isEmpty, "PokeAPI values the engine doesn't know:\n\(unknown.joined(separator: "\n"))")
    }

    @Test("Every learnable damaging move without a base power is modeled or excluded")
    func powerlessDamagingMovesDecided() {
        let undecided = Self.learnable.filter { move in
            move.damageClassKind != .status && (move.power ?? 0) == 0
                && !MoveClassification.computedPowerMoves.contains(move.name)
                && !MoveClassification.fixedDamageMoves.contains(move.name)
                && !MoveClassification.unsupportedMoves.contains(move.name)
                && !MoveClassification.selfKOMoves.contains(move.name)
        }
        #expect(undecided.isEmpty, "Damaging moves with no power and no decision: \(undecided.map(\.name))")
    }

    @Test("Modeled powerless moves get a power or a fixed damage")
    func powerlessMovesResolve() {
        let attacker = Combatant(pokemon: PokeAPISnapshot.pokemon[0], moves: [])
        let defender = Combatant(pokemon: PokeAPISnapshot.pokemon[1], moves: [])
        let unresolved = Self.learnable.filter { $0.isBattleReady && $0.isDamage }.filter { move in
            let power = DamageCalculator.power(
                of: move, attacker: attacker, defender: defender,
                context: TurnContext(attackerMovesFirst: true)
            )
            switch power {
            case .power(let p)?: return p <= 0
            case .fixed(let d)?: return d < 0
            case nil: return true
            }
        }
        #expect(unresolved.isEmpty, "Battle-ready damaging moves with no power: \(unresolved.map(\.name))")
    }

    @Test("Moves without PokeAPI meta data have reviewed stat change targets")
    func unknownCategoryMovesReviewed() {
        var problems: [String] = []
        for move in Self.learnable where move.category == Move.unknownCategory && !move.statChanges.isEmpty {
            guard let expected = Self.reviewedUnknownCategoryTargets[move.name] else {
                problems.append("\(move.name): not reviewed")
                continue
            }
            let actual = Set(move.statChanges.map(\.target))
            if actual != [expected] { problems.append("\(move.name): resolves to \(actual), expected \(expected)") }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("Self-debuff moves lower their user's stats, not the target's")
    func selfDebuffsTargetUser() {
        let wrong = Self.learnable
            .filter { MoveClassification.selfDebuffMoves.contains($0.name) }
            .filter { move in move.statChanges.contains { $0.target != .user } }
        #expect(wrong.isEmpty, "\(wrong.map(\.name))")
    }

    @Test("Battle-ready moves in unusual categories are explicitly modeled or approximated")
    func unusualMovesDecided() {
        let modeled: Set<String> = ["rest", "shell-smash"]
        let undecided = Self.learnable.filter { move in
            Self.unusualCategories.contains(move.category) && move.isBattleReady
                && !modeled.contains(move.name)
                && MoveClassification.approximations[move.name] == nil
        }
        #expect(undecided.isEmpty, "Decide (model, approximate or exclude): \(undecided.map(\.name))")
    }

    @Test("Toxic and other bad-poison moves escalate")
    func badPoisonMovesKnown() {
        let toxic = PokeAPISnapshot.moves["toxic"]
        #expect(toxic?.inflictsBadPoison == true)
        #expect(toxic?.isBattleReady == true)
    }

    @Test("Catalogue report", .tags(.report))
    func report() {
        var excluded: [String: [String]] = [:]
        var approximated: [String] = []
        var full = 0
        for move in Self.learnable {
            if let reason = Self.exclusionReason(move) {
                excluded[reason, default: []].append(move.name)
            } else if MoveClassification.approximations[move.name] != nil
                        || Self.ignoredAilments.subtracting(["none"]).contains(move.ailment) {
                approximated.append(move.name)
            } else {
                full += 1
            }
        }
        let ready = full + approximated.count
        print("""
        Move catalogue: \(PokeAPISnapshot.moves.count) moves, \(Self.learnable.count) learnable
        Battle-ready: \(ready) (\(full) fully modeled, \(approximated.count) with an ignored side effect)
        Excluded: \(excluded.values.map(\.count).reduce(0, +))
        """)
        for (reason, names) in excluded.sorted(by: { $0.value.count > $1.value.count }) {
            print("  \(reason): \(names.count)")
        }
        #expect(ready > 0)
    }

    static func exclusionReason(_ move: Move) -> String? {
        if MoveClassification.chargingMoves.contains(move.name) { return "two-turn move" }
        if MoveClassification.selfKOMoves.contains(move.name) { return "self-KO move" }
        if MoveClassification.unsupportedMoves.contains(move.name) { return "unsupported mechanic" }
        if !move.isBattleReady { return "no modeled effect (field, switching, protection, ...)" }
        return nil
    }
}

extension Tag {
    /// Tests that mainly print a report.
    @Tag static var report: Self
}
