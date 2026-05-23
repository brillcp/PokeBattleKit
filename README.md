# PokeBattleKit

A standalone Swift package for simulating Pokemon battles, powered by [PokeAPI](https://pokeapi.co).
Used in [PokedexUI](https://github.com/brillcp/pokedexui).

## Features

- **Type chart**: full Gen I-VIII effectiveness matchups via `TypeChart` (conforms to `TypeEffectivenessProviding`)
- **Damage calculator**: Gen-V formula with STAB, type effectiveness, crit, burn penalty, stat stages (`DamageCalculator`)
- **Battle engine**: turn-based 1v1 combat with speed priority, stat stages, status effects (paralysis, burn, poison, sleep), recharge, and faint detection (`BattleEngine`)
- **Move classification**: recharge moves, self-debuff, charging, self-KO, and ailment sets (`MoveClassification`)
- **AI strategies**: deterministic scoring, heuristic picking, and post-pick corrections for three decisions:
  - `MoveScoring` + `MoveStrategy`: in-battle move selection with tunable weights and escalating recency penalties
  - `LoadoutStrategy`: 4-move loadout selection with shortlisting, filling, and fairness handicapping
  - `OpponentStrategy` + `Candidate`: opponent pool filtering and mutual-threat ranking
- **PokeAPI networking + disk cache**: fetches and caches all moves (~937) and type data on first launch, reads from disk on subsequent launches
- **Protocol-driven**: `MoveData`, `PokemonData`, and `TypeEffectivenessProviding` let consumers use their own model types

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.0+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/brillcp/PokeBattleKit", .upToNextMinor(from: "0.0.9"))
]
```

## Usage

### Initialization

Call once at app launch to fetch and cache moves + type data from PokeAPI:

```swift
import PokeBattleKit

try await PokeBattleKit.initialize()
```

Subsequent calls are no-ops. The type chart and move catalogue are then available via `PokeBattleKit.typeChart` and `PokeBattleKit.allMoves`.

### Running a battle

```swift
let player = Combatant(pokemon: playerData, moves: playerMoveSnapshots, hpBonus: 1.2)
let opponent = Combatant(pokemon: opponentData, moves: opponentMoveSnapshots)
let state = BattleState(player: player, opponent: opponent)
var engine = BattleEngine(state: state, typeChart: PokeBattleKit.typeChart)

let events = engine.resolveRound(playerMove: thunderbolt, opponentMove: flamethrower)
for event in events {
    // .used, .damaged, .statusApplied, .fainted, .ended, etc.
}
```

### AI strategies

The AI layer provides deterministic heuristics designed to pair with an LLM (or work standalone):

```swift
let chart = PokeBattleKit.typeChart

// Score a move in battle context
let score = MoveScoring.inBattleScore(
    move: thunderbolt, attacker: player, defender: opponent,
    typeChart: chart, recentMoves: ["thunderbolt", "ice-beam"]
)

// Heuristic best move
let pick = MoveStrategy.heuristicPick(
    attacker: player, defender: opponent, moves: loadout, typeChart: chart, recentMoves: []
)

// Build a 4-move loadout
let loadout = LoadoutStrategy.heuristicPick(
    fighter: opponent, opponent: player, moves: fullMovePool, typeChart: chart
)

// Filter and rank opponent candidates
let pool = OpponentStrategy.balancedPool(
    from: candidates, playerBST: 500, playerTypes: ["water"], chart: chart
)
let opponentId = OpponentStrategy.heuristicPick(
    player: playerCandidate, candidates: pool, typeChart: chart
)
```

### Tuning weights

All scoring weights are public in `MoveScoring.Weights`. Fork and adjust to change AI behavior:

| Weight | Default | Effect |
| --- | --- | --- |
| `koBonus` | 55 | How aggressively the AI targets KOs |
| `repeatFirst` / `repeatSecond` / `repeatThird` | 18 / 40 / 65 | Escalating penalty for repeating the same move |
| `lowHPHealBonus` | 35 | How eagerly the AI heals when hurt |
| `paralysisFaster` | 28 | Value of paralyzing a faster opponent |
| `burnPhysical` | 24 | Value of burning a physical attacker |

See [`MoveScoring.swift`](Sources/PokeBattleKit/AI/MoveScoring.swift) for the full list.

## Architecture

```
PokeBattleKit/
  PokeBattleKit.swift     Entry point, initialize(), move lookup
  AI/                     MoveScoring, MoveStrategy, LoadoutStrategy, OpponentStrategy
  Engine/                 BattleEngine, DamageCalculator
  Models/                 Move (Codable model from PokeAPI)
  MoveClassification/     DamageClass, recharge/self-debuff/charging sets
  Networking/             PokeAPIClient (internal, fetches moves + types)
  Cache/                  DiskCache (internal, JSON file persistence)
  Protocols/              MoveData, PokemonData, TypeEffectivenessProviding
  State/                  Combatant, BattleState, Event, Side, Status, MoveSnapshot
  TypeChart/              TypeChart, TypeMatchup
```

## License

MIT
