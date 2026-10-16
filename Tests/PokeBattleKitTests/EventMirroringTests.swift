import Foundation
import Testing
@testable import PokeBattleKit

/// Pins down `Event.mirrored`: every side flips, nothing else changes.
@Suite("Event mirroring")
struct EventMirroringTests {
    /// One of every case, each happening to the player.
    static let events: [Event] = [
        .used(.player, moveName: "tackle"),
        .missed(.player),
        .damaged(.player, amount: 42, effectiveness: 2, crit: true),
        .statusApplied(.player, .burn),
        .statusTick(.player, .poison, amount: 6),
        .statChanged(.player, stat: "attack", delta: -1),
        .healed(.player, amount: 20),
        .recoil(.player, amount: 10),
        .recharging(.player),
        .wokeUp(.player),
        .fastAsleep(.player),
        .frozenSolid(.player),
        .thawed(.player),
        .fullyParalyzed(.player),
        .lostFocus(.player),
        .flinched(.player),
        .failed(.player),
        .hitCount(.player, count: 3),
        .fainted(.player),
        .ended(winner: .player),
    ]

    /// `Event` isn't `Equatable`; its JSON form covers every field.
    static func json(_ event: Event) throws -> [String: AnyHashable] {
        let data = try JSONEncoder().encode(event)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
    }

    @Test("Flips the side and keeps every other field", arguments: events)
    func flipsSide(_ event: Event) throws {
        var expected = try Self.json(event)
        let key = expected["side"] != nil ? "side" : "winner"
        expected[key] = "opponent"
        #expect(try Self.json(event.mirrored) == expected)
    }

    @Test("Mirroring twice gives the original event", arguments: events)
    func roundTrips(_ event: Event) throws {
        #expect(try Self.json(event.mirrored.mirrored) == Self.json(event))
    }

    @Test("A draw stays a draw")
    func draw() throws {
        #expect(try Self.json(Event.ended(winner: nil).mirrored) == Self.json(.ended(winner: nil)))
    }
}
