import Foundation
import Testing
@testable import PokeBattleKit

/// Pins down the two-device turn protocol: two `PeerBattle`s wired straight
/// to each other, with no transport.
@Suite("Peer battle")
struct PeerBattleTests {
    /// A plain 40-power Normal attack (`Move` is only built from PokeAPI data).
    static let strike: Move = {
        let json = """
        {"name": "strike", "power": 40, "accuracy": 100, "pp": 35, "priority": 0,
         "damage_class": {"name": "physical"}, "type": {"name": "normal"}, "effect_chance": null,
         "target": {"name": "selected-pokemon"}, "meta": null, "stat_changes": []}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return Move(from: try! decoder.decode(APIMoveResponse.self, from: Data(json.utf8)))
    }()

    /// A host and a guest set up for the same battle, each from its own side.
    struct Pair {
        var host: PeerBattle
        var guest: PeerBattle
        /// Everything each device was told to play, in order.
        var hostPlayed: [Event] = []
        var guestPlayed: [Event] = []
        var guestEnded: [Side?] = []

        init(hostHP: Int = 100, guestHP: Int = 100) {
            let hostFighter = Combatant(pokemon: EngineTests.pokemon(name: "Host", hp: hostHP, speed: 90), moves: [])
            let guestFighter = Combatant(pokemon: EngineTests.pokemon(name: "Guest", hp: guestHP, speed: 70), moves: [])
            host = PeerBattle(
                role: .host,
                state: BattleState(player: hostFighter, opponent: guestFighter),
                typeChart: EngineTests.chart,
                peerMoves: [strike]
            )
            guest = PeerBattle(
                role: .guest,
                state: BattleState(player: guestFighter, opponent: hostFighter),
                typeChart: EngineTests.chart,
                peerMoves: [strike]
            )
        }

        mutating func hostCommits() { run(host.commit(strike), from: .host) }
        mutating func guestCommits() { run(guest.commit(strike), from: .guest) }

        /// Carry out `steps` from one device, delivering its messages to the
        /// other straight away.
        mutating func run(_ steps: [PeerBattle.Step], from role: PeerBattle.Role) {
            for step in steps {
                switch step {
                case .send(let message):
                    let replies = role == .host ? guest.receive(message) : host.receive(message)
                    run(replies, from: role == .host ? .guest : .host)
                case .play(let events):
                    if role == .host { hostPlayed += events } else { guestPlayed += events }
                case .ended(let winner):
                    if role == .guest { guestEnded.append(winner) }
                case .peerCommitted:
                    break
                }
            }
        }
    }

    /// `Event` isn't `Equatable`; its JSON form covers every field.
    static func json(_ events: [Event]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(events), as: UTF8.self)
    }

    @Test("Resolves when the host commits first, and the guest plays the same round mirrored")
    func hostFirst() throws {
        var pair = Pair()
        pair.hostCommits()
        #expect(pair.hostPlayed.isEmpty, "The host waits for the guest's move")
        pair.guestCommits()
        #expect(!pair.hostPlayed.isEmpty)
        #expect(try Self.json(pair.guestPlayed) == Self.json(pair.hostPlayed.map(\.mirrored)))
        #expect(pair.host.committedMove == nil && pair.guest.committedMove == nil)
    }

    @Test("Resolves when the guest commits first")
    func guestFirst() throws {
        var pair = Pair()
        pair.guestCommits()
        #expect(pair.hostPlayed.isEmpty)
        pair.hostCommits()
        #expect(!pair.hostPlayed.isEmpty)
        #expect(try Self.json(pair.guestPlayed) == Self.json(pair.hostPlayed.map(\.mirrored)))
    }

    @Test("Tells the side that hasn't committed yet that the peer has")
    func peerCommittedPrompt() {
        var pair = Pair()
        let steps = pair.guest.commit(Self.strike)
        guard case .send(let message) = steps.first else {
            Issue.record("Committing should send the move")
            return
        }
        let replies = pair.host.receive(message)
        #expect(replies.contains { if case .peerCommitted = $0 { true } else { false } })
    }

    @Test("Plays a whole battle to the end on both devices")
    func wholeBattle() throws {
        // The host is faster and the guest has little HP, so the host wins.
        var pair = Pair(guestHP: 30)
        var rounds = 0
        func isOver() -> Bool {
            if case .ended? = pair.hostPlayed.last { return true }
            return false
        }
        while !isOver(), rounds < 50 {
            if rounds.isMultiple(of: 2) { pair.hostCommits(); pair.guestCommits() }
            else { pair.guestCommits(); pair.hostCommits() }
            rounds += 1
        }
        guard case .ended(let winner)? = pair.hostPlayed.last else {
            Issue.record("The battle should end within 50 rounds")
            return
        }
        #expect(winner == .player)
        #expect(pair.guestEnded == [.opponent], "The guest hears it lost")
        #expect(try Self.json(pair.guestPlayed) == Self.json(pair.hostPlayed.map(\.mirrored)))
        #expect(pair.host.turnNumber == rounds && pair.guest.turnNumber == rounds)
    }

    @Test("Can't commit twice in one turn")
    func singleCommit() {
        var pair = Pair()
        pair.hostCommits()
        #expect(pair.host.commit(Self.strike).isEmpty)
        #expect(pair.host.turnNumber == 1)
    }

    @Test("Ignores stale, out-of-order and wrong-role messages")
    func ignoresBadMessages() {
        var pair = Pair()
        #expect(pair.host.receive(.moveCommitted(moveName: "strike", turnNumber: 5)).isEmpty, "A turn from the future")
        #expect(pair.guest.receive(.roundResolved(events: [], turnNumber: 1)).isEmpty, "A round the guest hasn't committed to")
        #expect(pair.host.receive(.roundResolved(events: [], turnNumber: 0)).isEmpty, "Only the host resolves rounds")
        #expect(pair.host.receive(.battleEnded(winner: .player)).isEmpty, "Only the host ends battles")

        pair.guestCommits()
        pair.hostCommits()
        let played = pair.hostPlayed.count
        #expect(pair.host.receive(.moveCommitted(moveName: "strike", turnNumber: 1)).isEmpty, "A repeat of a resolved turn")
        #expect(pair.hostPlayed.count == played)
    }

    @Test("The host only accepts moves from the peer's loadout")
    func unknownPeerMove() {
        var pair = Pair()
        pair.hostCommits()
        let steps = pair.host.receive(.moveCommitted(moveName: "hyper-beam", turnNumber: 1))
        #expect(!steps.contains { if case .play = $0 { true } else { false } })
        #expect(pair.host.committedMove != nil, "The round isn't resolved")
    }
}

@Suite("Battle message coding")
struct BattleMessageCodingTests {
    struct Fighter: Codable, Sendable, Equatable {
        let name: String
    }

    static func json(_ message: BattleMessage<Fighter>) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(message), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> BattleMessage<Fighter> {
        try JSONDecoder().decode(BattleMessage<Fighter>.self, from: Data(json.utf8))
    }

    @Test("Turn messages are flat in the message object")
    func flatTurnMessages() throws {
        #expect(try Self.json(.turn(.moveCommitted(moveName: "tackle", turnNumber: 3)))
            == #"{"moveName":"tackle","turnNumber":3,"type":"moveCommitted"}"#)
        #expect(try Self.json(.turn(.battleEnded(winner: nil))) == #"{"type":"battleEnded"}"#)
    }

    @Test("Every message survives a round trip", arguments: [
        BattleMessage<Fighter>.hello(protocolVersion: 3, displayName: "Ash", isHost: true),
        .challengeProposed(ChallengePayload(pokemon: Fighter(name: "pikachu"), moveNames: ["thunderbolt"])),
        .challengeAccepted(ChallengePayload(pokemon: Fighter(name: "eevee"), moveNames: ["tackle", "bite"])),
        .challengeDeclined,
        .turn(.moveCommitted(moveName: "tackle", turnNumber: 1)),
        .turn(.roundResolved(events: [.used(.player, moveName: "tackle"), .ended(winner: .player)], turnNumber: 1)),
        .turn(.battleEnded(winner: .opponent)),
        .rematch,
        .disconnect,
    ])
    func roundTrip(_ message: BattleMessage<Fighter>) throws {
        let encoded = try Self.json(message)
        #expect(try Self.json(Self.decode(encoded)) == encoded)
    }

    @Test("Unknown message types fail to decode")
    func unknownType() {
        #expect(throws: DecodingError.self) { try Self.decode(#"{"type":"teleport"}"#) }
    }
}
