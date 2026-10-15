#!/usr/bin/env python3
"""Fetches an offline PokeAPI snapshot for PokeBattleKit's whole-catalogue tests.

Writes Tests/PokeBattleKitTests/Resources/pokeapi-snapshot.json with:
- "moves": every move, trimmed to the fields PokeBattleKit decodes (raw PokeAPI
  JSON shape, so tests decode it through the package's own APIMoveResponse),
- "pokemon": every Pokémon (all forms) with id, name, weight (hectograms),
  types, base stats and the names of every move it can learn.

Run it again to refresh the snapshot when PokeAPI adds data:
    python3 Scripts/fetch_pokeapi_snapshot.py
"""
import json, os, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = "https://pokeapi.co/api/v2/"
OUT = os.path.join(os.path.dirname(__file__), "..", "Tests", "PokeBattleKitTests", "Resources", "pokeapi-snapshot.json")

def get(url):
    for attempt in range(4):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "PokeBattleKit-snapshot/1.0"})
            with urllib.request.urlopen(request, timeout=30) as r:
                return json.load(r)
        except Exception:
            if attempt == 3:
                raise
    return None

def trim_move(d):
    meta = d.get("meta")
    return {
        "name": d["name"], "power": d["power"], "accuracy": d["accuracy"], "pp": d["pp"],
        "priority": d["priority"], "damage_class": {"name": d["damage_class"]["name"]},
        "type": {"name": d["type"]["name"]}, "effect_chance": d["effect_chance"],
        "target": {"name": d["target"]["name"]},
        "stat_changes": [{"change": s["change"], "stat": {"name": s["stat"]["name"]}} for s in d["stat_changes"]],
        "meta": None if meta is None else {
            "ailment": {"name": meta["ailment"]["name"]}, "ailment_chance": meta["ailment_chance"],
            "drain": meta["drain"], "healing": meta["healing"], "category": {"name": meta["category"]["name"]},
            "min_hits": meta["min_hits"], "max_hits": meta["max_hits"],
            "crit_rate": meta["crit_rate"], "flinch_chance": meta["flinch_chance"],
        },
    }

def trim_pokemon(d):
    return {
        "id": d["id"], "name": d["name"], "weight": d["weight"],
        "types": [t["type"]["name"] for t in sorted(d["types"], key=lambda t: t["slot"])],
        "stats": {s["stat"]["name"]: s["base_stat"] for s in d["stats"]},
        "moves": sorted({m["move"]["name"] for m in d["moves"]}),
    }

def main():
    move_list = get(BASE + "move?limit=3000")["results"]
    pokemon_list = get(BASE + "pokemon?limit=3000")["results"]
    print(f"{len(move_list)} moves, {len(pokemon_list)} pokemon", file=sys.stderr)
    with ThreadPoolExecutor(max_workers=12) as pool:
        moves = list(pool.map(lambda i: trim_move(get(i["url"])), move_list))
        pokemon = list(pool.map(lambda i: trim_pokemon(get(i["url"])), pokemon_list))
    moves.sort(key=lambda m: m["name"])
    pokemon.sort(key=lambda p: p["id"])
    with open(OUT, "w") as f:
        json.dump({"source": "https://pokeapi.co", "moves": moves, "pokemon": pokemon}, f, separators=(",", ":"))
    print(f"wrote {OUT}", file=sys.stderr)

if __name__ == "__main__":
    main()
