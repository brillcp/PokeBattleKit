import Foundation

/// A fighter and the names of its chosen moves, sent by each side before a
/// battle between two devices. Only move names cross the wire; each device
/// rebuilds the ``Move`` values from its own catalogue.
///
/// `Fighter` is the host app's own summary of a Pokémon (it needs at least
/// what ``Combatant`` is built from, and can add sprites or cries).
public struct ChallengePayload<Fighter: Codable & Sendable>: Codable, Sendable {
    public let pokemon: Fighter
    public let moveNames: [String]

    public init(pokemon: Fighter, moveNames: [String]) {
        self.pokemon = pokemon
        self.moveNames = moveNames
    }
}

/// The messages of a battle's turns, the part ``PeerBattle`` produces and
/// consumes. Sent inside ``BattleMessage/turn(_:)``.
public enum TurnMessage: Codable, Sendable {
    /// A side committed its move for turn `turnNumber`. Sent by both sides;
    /// the host resolves the round once it holds both.
    case moveCommitted(moveName: String, turnNumber: Int)
    /// The host's resolved events for turn `turnNumber`, from the host's
    /// perspective.
    case roundResolved(events: [Event], turnNumber: Int)
    /// The battle ended on the host, from the host's perspective (`nil` for
    /// a draw).
    case battleEnded(winner: Side?)

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, moveName, turnNumber, events, winner
    }

    /// The `type` strings this enum encodes, for ``BattleMessage`` to route.
    static let types: Set<String> = ["moveCommitted", "roundResolved", "battleEnded"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "moveCommitted":
            self = .moveCommitted(
                moveName: try c.decode(String.self, forKey: .moveName),
                turnNumber: try c.decode(Int.self, forKey: .turnNumber)
            )
        case "roundResolved":
            self = .roundResolved(
                events: try c.decode([Event].self, forKey: .events),
                turnNumber: try c.decode(Int.self, forKey: .turnNumber)
            )
        case "battleEnded":
            self = .battleEnded(winner: try c.decodeIfPresent(Side.self, forKey: .winner))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown TurnMessage type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .moveCommitted(let name, let turn):
            try c.encode("moveCommitted", forKey: .type)
            try c.encode(name, forKey: .moveName)
            try c.encode(turn, forKey: .turnNumber)
        case .roundResolved(let events, let turn):
            try c.encode("roundResolved", forKey: .type)
            try c.encode(events, forKey: .events)
            try c.encode(turn, forKey: .turnNumber)
        case .battleEnded(let winner):
            try c.encode("battleEnded", forKey: .type)
            try c.encodeIfPresent(winner, forKey: .winner)
        }
    }
}

/// Every message two devices exchange over a battle's lifetime: the
/// greeting, the challenge exchange, the turns, and leaving. Send it over
/// any transport (MultipeerConnectivity, Game Center, a socket).
///
/// Encoded by hand as a flat JSON object with a `"type"` discriminator
/// (e.g. `{"type":"moveCommitted","moveName":"tackle","turnNumber":3}`), so
/// the format is explicit and stable; turn messages are flattened into the
/// same object. The `type` strings and keys are the wire format: changing
/// them breaks compatibility with other installs, so apps should exchange a
/// protocol version in ``hello(protocolVersion:displayName:isHost:)`` and
/// bump it with any change (including a new ``Event`` case or a rules
/// change in a new release of this package).
public enum BattleMessage<Fighter: Codable & Sendable>: Codable, Sendable {
    /// The first message both peers send once connected: the app's protocol
    /// version and each side's role.
    case hello(protocolVersion: Int, displayName: String, isHost: Bool)
    /// The host announces its loadout.
    case challengeProposed(ChallengePayload<Fighter>)
    /// The guest accepts and announces its own loadout.
    case challengeAccepted(ChallengePayload<Fighter>)
    /// The guest declines the challenge.
    case challengeDeclined
    /// A turn of the battle (see ``PeerBattle``).
    case turn(TurnMessage)
    /// Either side asks for a fresh battle with new loadouts.
    case rematch
    /// Either side leaves cleanly.
    case disconnect

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, displayName, isHost, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        if TurnMessage.types.contains(type) {
            self = .turn(try TurnMessage(from: decoder))
            return
        }
        switch type {
        case "hello":
            self = .hello(
                protocolVersion: try c.decode(Int.self, forKey: .protocolVersion),
                displayName: try c.decode(String.self, forKey: .displayName),
                isHost: try c.decode(Bool.self, forKey: .isHost)
            )
        case "challengeProposed":
            self = .challengeProposed(try c.decode(ChallengePayload<Fighter>.self, forKey: .payload))
        case "challengeAccepted":
            self = .challengeAccepted(try c.decode(ChallengePayload<Fighter>.self, forKey: .payload))
        case "challengeDeclined":
            self = .challengeDeclined
        case "rematch":
            self = .rematch
        case "disconnect":
            self = .disconnect
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown BattleMessage type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .turn(let message) = self {
            try message.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let version, let name, let isHost):
            try c.encode("hello", forKey: .type)
            try c.encode(version, forKey: .protocolVersion)
            try c.encode(name, forKey: .displayName)
            try c.encode(isHost, forKey: .isHost)
        case .challengeProposed(let payload):
            try c.encode("challengeProposed", forKey: .type)
            try c.encode(payload, forKey: .payload)
        case .challengeAccepted(let payload):
            try c.encode("challengeAccepted", forKey: .type)
            try c.encode(payload, forKey: .payload)
        case .challengeDeclined:
            try c.encode("challengeDeclined", forKey: .type)
        case .rematch:
            try c.encode("rematch", forKey: .type)
        case .disconnect:
            try c.encode("disconnect", forKey: .type)
        case .turn:
            break // Encoded above.
        }
    }
}
