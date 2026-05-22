# PokeBattleKit

A standalone Swift package for simulating Pokemon battles, powered by [PokeAPI](https://pokeapi.co).
Used in [PokedexUI](https://github.com/brillcp/pokedexui).

## Features

- Type effectiveness chart with full Gen I-VIII matchup support
- Damage calculation using the official Pokemon damage formula
- Battle engine with turn-based combat, stat stages, and status effects
- Move classification (recharge, self-debuff, charging, self-KO)
- AI-friendly APIs for move evaluation and loadout scoring

## Requirements

- iOS 18+
- Swift 6.0+

## Installation

Add PokeBattleKit as a Swift Package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/brillcp/PokeBattleKit", from: "0.1.0")
]
```

## Usage

```swift
import PokeBattleKit

// Build combatants with move snapshots
let player = BattleCombatant(pokemon: playerData, moves: playerMoves, hpBonus: 0)
let opponent = BattleCombatant(pokemon: opponentData, moves: opponentMoves, hpBonus: 0)

// Set up battle state
let state = BattleState(player: player, opponent: opponent)

// Create engine with type chart
var engine = BattleEngine(state: state, typeChart: typeChart)

// Resolve a round
let events = engine.resolveRound(playerMove: thunderbolt, opponentMove: flamethrower)
```

## License

MIT
