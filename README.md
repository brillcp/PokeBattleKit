# PokeBattleKit

A standalone Swift package for simulating Pokemon battles, powered by [PokeAPI](https://pokeapi.co).
Used in [PokedexUI](https://github.com/brillcp/pokedexui). Written by [Viktor Gidlöf](https://viktorgidlof.com)

## Features

- **Type chart**: full Gen I-VIII effectiveness matchups via `TypeChart` (conforms to `TypeEffectivenessProviding`)
- **Main-series stats**: combatants use the main-series stat formulas with perfect IVs, no EVs and a neutral nature, at `BattleRules.level` (50 by default). The AI opponent's level varies with the `Difficulty` (see [AI strategies](#ai-strategies))
- **Battle bulk**: max HP is scaled so a reference attack takes `BattleRules.referenceHitsToKO` hits (12 by default, about 4x real-game HP) while each hit stays real-game size, so a one-on-one fight without switching lasts several turns instead of one or two. Healing, Rest, and burn and poison damage use the real HP (`baseMaxHP`), so they keep their real-game size relative to attacks. Use `BattleRules.realGameHP` for real-game HP
- **Damage calculator**: Gen-V+ formula with STAB, uncapped type effectiveness (4x weaknesses hit 4x), 1-in-24 crits that ignore unfavourable stat stages, high-crit moves, burn penalty, stat stages, and multi-hit moves (`DamageCalculator`)
- **Battle engine**: turn-based 1v1 combat with move priority and stage-adjusted speed, stat stages, flinching, status effects (paralysis, burn, poison, Toxic's escalating poison, sleep for 1-3 turns) with type immunities (Electric can't be paralyzed, Fire can't be burned, Poison/Steel can't be poisoned, Thunder Wave fails on Ground), 2-5 hit moves, Fake Out on the first turn only, recharge, and faint detection (`BattleEngine`)
- **Move classification**: recharge, self-debuff, charging, self-KO, first-turn-only and unsupported move sets (`MoveClassification`). `MoveData.isBattleReady` drops moves the engine can't model faithfully (confusion-only, accuracy/evasion, Leech Seed, trapping, Belly Drum, ...)
- **Situational power** (`DamageCalculator.power(of:attacker:defender:context:)`): Return/Frustration, weight-based (Low Kick, Heavy Slam), HP-based (Reversal, Crush Grip), Speed-based (Gyro Ball, Electro Ball), stage-based (Stored Power, Punishment), conditional doubling (Facade, Hex, Venoshock, Brine, Acrobatics, Avalanche, Payback, Bolt Beak, Assurance), fixed damage (Seismic Toss, Night Shade, Super Fang, Endeavor), and stat swaps (Foul Play, Body Press, Psyshock)
- **Freeze**: 20% thaw chance per turn, thawed by Fire attacks, Ice types immune
- **Every Pokémon can battle**: forms with tiny PokeAPI learnsets use their base species' (`PokemonForms`), and `LoadoutStrategy.withFallbackAttack` adds Struggle (typeless, quarter-HP recoil) when nothing else can attack
- **Species-specific moves**: `SpeciesMoveRules` resolves moves that depend on their user before the engine or AI uses them: Ivy Cudgel takes Ogerpon's mask type, Raging Bull the Paldean Tauros breed type, Aura Wheel Morpeko's mode, Revelation Dance/Judgment/Multi-Attack the user's type, and Tera Blast only lowers its user's stats for Stellar Terapagos
- **Data-driven stat changes**: who a move's stat changes hit comes from PokeAPI's move `target` and `meta.category`, so Close Combat lowers its user's defences and Crunch the target's
- **AI strategies**: scoring, heuristic picking, and post-pick corrections for three decisions, all with a `Difficulty` (`.easy`, `.fair` (default), `.hard`):
  - `MoveScoring` + `MoveStrategy`: in-battle move selection that values every move in HP of damage, including boosts, statuses and heals, and is aware of KO and speed threats
  - `LoadoutStrategy`: role-based 4-move loadouts (two attack types, then status/boost/heal or coverage), shortlisting, filling, and an easy-mode handicap
  - `MatchmakingStrategy` + `Candidate`: fair matchups by simulated strength (`PokemonStrength`) and type matchup, and a weighted random pick favouring tense matchups. Fairness is symmetric, so it picks an opponent for a player or a player for an opponent
- **Strength ratings** (`PokemonStrength`): an Elo-style rating for every Pokémon from simulated battles under these rules (shipped as `strength-ratings.json`), with a BST-based estimate for anything unrated
- **Battles between two devices**: `PeerBattle` runs the host-authoritative turn protocol (commit, resolve, replay, with stale messages ignored) over any transport, `BattleMessage` is the wire format, and `Event.mirrored` flips a round's events to the other device's side (see [Battles between two devices](#battles-between-two-devices))
- **Battle simulator** (`BattleSimulator`): headless AI-vs-AI battles, used by the tests and the rating generator
- **PokeAPI networking + disk cache**: fetches and caches all moves (~937) and type data on first launch, reads from disk on subsequent launches
- **Protocol-driven**: `MoveData`, `PokemonData`, and `TypeEffectivenessProviding` let consumers use their own model types
- **Swift 6 concurrency-safe**: value-type, `Sendable` engine and state; the shared catalogue is guarded by a `Mutex` (see [Concurrency](#concurrency))

## Requirements

- iOS 18+ / macOS 15+ (the `Synchronization` framework's `Mutex`)
- Swift 6.0+ (Swift 6 language mode)

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/brillcp/PokeBattleKit", .upToNextMajor(from: "0.2.0"))
]
```

## Usage

### Initialization

Call once at app launch to fetch and cache moves + type data from PokeAPI:

```swift
import PokeBattleKit

try await PokeBattleKit.initialize()
```

Subsequent calls are no-ops, and concurrent calls share a single in-flight load. If loading fails, the error is thrown and the next call retries. The type chart and move catalogue are then available via `PokeBattleKit.typeChart` and `PokeBattleKit.allMoves`, from any thread.

### Running a battle

```swift
let player = Combatant(pokemon: playerData, moves: playerMoveSnapshots)
let opponent = Combatant(pokemon: opponentData, moves: opponentMoveSnapshots)
let state = BattleState(player: player, opponent: opponent)
var engine = BattleEngine(state: state, typeChart: PokeBattleKit.typeChart)

let events = engine.resolveRound(playerMove: thunderbolt, opponentMove: flamethrower)
for event in events {
    // .used, .damaged, .hitCount, .flinched, .statusApplied, .fainted, .ended, etc.
}
```

### Battles between two devices

`PeerBattle` is one device's half of a two-device battle, with no networking of its own: the host runs the engine, and both devices play the host's resolved rounds, so rolls can't diverge. Each device sees the battle from its own side. Feed it this device's moves and the peer's messages, and carry out the steps it returns; `BattleMessage<Fighter>` is the whole wire format (greeting, challenge exchange, turns), generic over your app's fighter summary, to send over any transport:

```swift
var battle = PeerBattle(role: .host, state: state, typeChart: chart, peerMoves: theirMoves)

func perform(_ steps: [PeerBattle.Step]) async {
    for step in steps {
        switch step {
        case .send(let turn): transport.send(BattleMessage<MyFighter>.turn(turn))
        case .play(let events): await animate(events)   // already from this device's side
        case .peerCommitted: showPrompt("Choose your move")
        case .ended(let winner): showResult(winner)
        }
    }
}

await perform(battle.commit(myMove))
// When a message arrives:
if case .turn(let turn) = message { await perform(battle.receive(turn)) }
```

### AI strategies

The AI layer is rule-based. Scoring is deterministic; picking depends on the `Difficulty`:

| Difficulty | Opponent level | Loadout | Move choice |
| --- | --- | --- | --- |
| `.easy` | 6 below the player | Strongest attack swapped for a weak one | Random among moves within 35% of the best |
| `.fair` (default) | Same as the player | No handicap | Weighted random among moves within 10% of the best |
| `.hard` | 7 above the player | No handicap | Always the best-scoring move |

The level gaps (`Difficulty.opponentLevelOffset`, applied with `BattleRules.opponentLevel(for:)`) are calibrated with the balance simulation so a good player wins about 90% / 50% / 20% of battles (`Difficulty.targetPlayerWinRate`); a test keeps them there.

Everything that rolls takes a `using:` random number generator: the engine (`BattleEngine.resolveRound`, `DamageCalculator.computeDamage`), the AI (`MoveStrategy.heuristicPick`, `LoadoutStrategy.adjust`, `MatchmakingStrategy.pick`) and `BattleSimulator.battle`, so a seeded simulation replays exactly. Overloads without it use the system generator.

```swift
let chart = PokeBattleKit.typeChart

// Score a move in battle context
let score = MoveScoring.inBattleScore(
    move: thunderbolt, attacker: player, defender: opponent,
    typeChart: chart, recentMoves: ["thunderbolt", "ice-beam"]
)

// Heuristic move pick (fair by default)
let pick = MoveStrategy.heuristicPick(
    attacker: player, defender: opponent, moves: loadout, typeChart: chart,
    recentMoves: [], difficulty: .fair
)

// Reason only with the moves the player has revealed so far
let scouted = player.knowing(onlyMoves: ["thunderbolt"])

// Build a 4-move loadout
let loadout = LoadoutStrategy.heuristicPick(
    fighter: opponent, opponent: player, moves: fullMovePool, typeChart: chart
)

// Pick a fair opponent (by simulated strength), skipping recent ones
let opponent = MatchmakingStrategy.pick(
    for: playerCandidate, from: candidates, typeChart: chart, excluding: recentIDs
)
let chance = MatchmakingStrategy.predictedWinChance(of: playerCandidate, against: opponent!)

// Run a whole AI-vs-AI battle headlessly
var rng = SystemRandomNumberGenerator()
let result = BattleSimulator.battle(
    player: .init(pokemon: bulbasaur, movepool: bulbasaurMoves),
    opponent: .init(pokemon: charmander, movepool: charmanderMoves, difficulty: .hard),
    typeChart: chart, using: &rng
)
```

### Tuning weights

`MoveScoring` values every move in one unit, HP of damage. An attack is worth the damage it's expected to deal (capped at the target's remaining HP) plus a KO bonus scaled by the chance of a KO. A support move is worth the damage it gains or prevents over the next few actions, worked out from a short forecast of the fight: each side's best damage per action, who moves first, and how many actions each side gets before fainting. So a Swords Dance is worthless when the AI is about to be KO'd, a heal is worthless at full HP, and burning a physical attacker is worth the damage it won't deal.

The remaining weights are public in `MoveScoring.Weights`:

| Weight | Default | Effect |
| --- | --- | --- |
| `koBonus` | 40 | Bonus for a KO, scaled by its chance (accuracy and damage roll) |
| `twoHitKOBonus` | 10 | Bonus for an attack that sets up a KO next turn |
| `futureDiscount` | 0.75 | Discount on value that only pays off in later turns |
| `horizon` | 2 | How many future actions boosts, statuses and heals are valued over |
| `repeatPenalty` | 3 | Mild penalty per turn of repeating a move, to vary near-equal picks |

See [`MoveScoring.swift`](Sources/PokeBattleKit/AI/MoveScoring.swift) for the full list.

## Concurrency

PokeBattleKit builds in the **Swift 6 language mode**, so data-race safety is checked by the compiler:

| Type | Model | Why |
| --- | --- | --- |
| `BattleEngine`, `BattleState`, `Combatant`, `Event`, `Move`, `TypeChart` | `Sendable` value types | Copy freely between actors; mutate a local `var engine` |
| `PokeBattleKit` catalogue (moves + type chart) | `Mutex`-guarded static state (Synchronization) | Written once by `initialize()`, read from any thread without `nonisolated(unsafe)` |
| `PokeAPIClient` (internal) | Stateless `Sendable` struct | ~950 move requests download and decode in parallel task-group children |
| `DiskCache` (internal) | `Sendable` struct | Atomic JSON writes in the Caches directory |

The AI strategies (`MoveScoring`, `MoveStrategy`, `LoadoutStrategy`, `MatchmakingStrategy`) are pure static functions over `Sendable` inputs, so they can run on any actor, including off the main thread for heavy pool scoring.

## Testing

The test suite uses **Swift Testing** (`import Testing`), with descriptive `@Test("…")` names, parameterized tests (`@Test(arguments:)`) for input/expected tables, and `#require` for preconditions. Run it with:

```sh
swift test
```

The whole-Pokédex and balance simulations play thousands of seeded battles, so they only run with `SIMULATE=1` (in release; a few minutes):

```sh
SIMULATE=1 swift test -c release -Xswiftc -enable-testing --filter "PokedexSimulationTests|BalanceSimulationTests"
```

The suite runs against an offline snapshot of all of PokeAPI (`Tests/PokeBattleKitTests/Resources/pokeapi-snapshot.json`; refresh with `python3 Scripts/fetch_pokeapi_snapshot.py`), so battle quality is checked for every move and every Pokémon, not just the battles someone plays:

- `MoveCatalogAuditTests` decodes every move through the package's own PokeAPI decoding and fails if any value the engine reads is unknown, or if a learnable move with an unusual mechanic isn't explicitly modeled, approximated (`MoveClassification.approximations`) or excluded. It prints a catalogue report.
- `PokedexSimulationTests` runs AI-vs-AI battles across the whole Pokédex, with opponents picked by `MatchmakingStrategy.pick` as an app would, and checks every battle: no unusable move picked, a real attack in every loadout, no sure KO passed up on hard, several turns per battle, no stalls, each difficulty's target win rate, and that the strength ratings still predict outcomes.

After changing the rules or the AI, regenerate the ratings, then recalibrate the difficulty level gaps (both run in release; a few minutes each):

```sh
GENERATE_RATINGS=1 swift test -c release -Xswiftc -enable-testing --filter generateStrengthRatings
CALIBRATE=1 swift test -c release -Xswiftc -enable-testing --filter calibrateDifficulty
```
- `BalanceSimulationTests` is the quick version over 24 hand-picked fixture Pokémon.

## Modernization

The Swift Testing suite follows the `modernize-tests` guidance from the **agent skills Apple ships for Xcode's coding assistant** (export them with `xcrun agent skills export --output-dir <path>`): descriptive test names, parameterized tests, and `#require` for preconditions.

Separately, a Swift 6 concurrency pass replaced the `nonisolated(unsafe)` globals with a `Mutex` and moved the network client off a serializing actor, so responses decode in parallel.

## Architecture

```
PokeBattleKit/
  PokeBattleKit.swift     Entry point, initialize(), move lookup (Mutex-guarded catalogue)
  AI/                     Difficulty, MoveScoring, MoveStrategy, LoadoutStrategy, MatchmakingStrategy, PokemonStrength
  Simulation/             BattleSimulator
  Resources/              strength-ratings.json
  Engine/                 BattleEngine, DamageCalculator, StatStage
  Models/                 Move (Codable model from PokeAPI)
  MoveClassification/     DamageClass, recharge/self-debuff/charging/unsupported move sets
  Multiplayer/            PeerBattle (two-device turn protocol), BattleMessage, TurnMessage, ChallengePayload
  Networking/             PokeAPIClient + PokeAPI response models (internal)
  Cache/                  DiskCache (internal, JSON file persistence)
  Protocols/              MoveData, PokemonData, TypeEffectivenessProviding
  State/                  Combatant, BattleState, Event, Phase, Side, Status, MoveSnapshot
  TypeChart/              TypeChart, TypeMatchup
```

## License

MIT
