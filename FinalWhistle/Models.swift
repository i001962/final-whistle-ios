import Foundation

// MARK: - FID

/// A Farcaster FID. The public HTTP API is inconsistent about the JSON type:
/// casts carry it as a number, the user endpoint carries it as a string, so
/// decode either form. Native Hypersnap FIDs start at 4294967296 (2^32).
struct FID: Codable, Hashable, Equatable, CustomStringConvertible {
    let value: UInt64

    init(_ value: UInt64) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(UInt64.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = UInt64(text) {
            value = number
        } else {
            throw DecodingError.typeMismatch(
                UInt64.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "FID is neither a number nor a numeric string")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    var description: String { String(value) }

    /// Display name fallback for a native FID with no fname: "fid:<fid>".
    var fallbackUsername: String { "fid:\(value)" }

    var isNative: Bool { value >= 4_294_967_296 }
}

// MARK: - Casts (public HTTP reads)

struct CastAuthor: Codable, Hashable {
    let fid: FID
    let username: String?
    let displayName: String?
    let pfpURL: URL?
    let bio: String?
    let followerCount: Int?
    let followingCount: Int?

    enum CodingKeys: String, CodingKey {
        case fid, username
        case displayName = "display_name"
        case pfpURL = "pfp_url"
        case profile
        case followerCount = "follower_count"
        case followingCount = "following_count"
    }

    struct Profile: Codable {
        struct Bio: Codable { let text: String? }
        let bio: Bio?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fid = try container.decode(FID.self, forKey: .fid)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        pfpURL = try container.decodeIfPresent(URL.self, forKey: .pfpURL)
        bio = try container.decodeIfPresent(Profile.self, forKey: .profile)?.bio?.text
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
        followingCount = try container.decodeIfPresent(Int.self, forKey: .followingCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fid, forKey: .fid)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(pfpURL, forKey: .pfpURL)
        try container.encodeIfPresent(followerCount, forKey: .followerCount)
        try container.encodeIfPresent(followingCount, forKey: .followingCount)
    }

    var displayUsername: String {
        if let username, !username.isEmpty { return username }
        return fid.fallbackUsername
    }

    var displayTitle: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return displayUsername
    }
}

struct CastReactions: Codable, Hashable {
    var likesCount: Int = 0
    var recastsCount: Int = 0

    init(likesCount: Int = 0, recastsCount: Int = 0) {
        self.likesCount = likesCount
        self.recastsCount = recastsCount
    }

    enum CodingKeys: String, CodingKey {
        case likesCount = "likes_count"
        case recastsCount = "recasts_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        likesCount = try container.decodeIfPresent(Int.self, forKey: .likesCount) ?? 0
        recastsCount = try container.decodeIfPresent(Int.self, forKey: .recastsCount) ?? 0
    }
}

struct CastReplies: Codable, Hashable {
    var count: Int = 0

    init(count: Int = 0) {
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }

    enum CodingKeys: String, CodingKey { case count }
}

/// One cast from the public read API. The hash is hex without a 0x prefix.
struct Cast: Codable, Hashable, Identifiable {
    let hash: String
    let text: String
    let timestamp: Date
    let author: CastAuthor
    var reactions: CastReactions
    let replies: CastReplies
    let parentHash: String?
    let parentAuthorFID: FID?
    let threadHash: String?

    var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, text, timestamp, author, reactions, replies
        case parentHash = "parent_hash"
        case parentAuthor = "parent_author"
        case threadHash = "thread_hash"
    }

    struct ParentAuthor: Codable {
        let fid: FID?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        author = try container.decode(CastAuthor.self, forKey: .author)
        reactions = try container.decodeIfPresent(CastReactions.self, forKey: .reactions) ?? CastReactions()
        replies = try container.decodeIfPresent(CastReplies.self, forKey: .replies) ?? CastReplies()
        parentHash = try container.decodeIfPresent(String.self, forKey: .parentHash)
        parentAuthorFID = try container.decodeIfPresent(ParentAuthor.self, forKey: .parentAuthor)?.fid
        threadHash = try container.decodeIfPresent(String.self, forKey: .threadHash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hash, forKey: .hash)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(author, forKey: .author)
        try container.encode(reactions, forKey: .reactions)
        try container.encode(replies, forKey: .replies)
        try container.encodeIfPresent(parentHash, forKey: .parentHash)
        try container.encodeIfPresent(threadHash, forKey: .threadHash)
    }
}

struct TrendingFeedResponse: Codable {
    let casts: [Cast]
}

/// The /football channel feed returns the same {"casts": [...]} shape.
typealias ChannelFeedResponse = TrendingFeedResponse

struct UserResponse: Codable {
    struct User: Codable {
        let fid: FID
        let username: String?
        let displayName: String?
        let pfpURL: URL?
        let custodyAddress: String?

        enum CodingKeys: String, CodingKey {
            case fid, username
            case displayName = "display_name"
            case pfpURL = "pfp_url"
            case custodyAddress = "custody_address"
        }
    }
    let user: User
}

struct UsernameLookupResponse: Codable {
    struct User: Codable { let fid: FID }
    let user: User
}

// MARK: - Identity (persisted, non-secret part)

/// Non-secret identity record, stored as JSON in Application Support.
/// The custody private key and the Ed25519 signer seed are NOT in here;
/// they live only in the Keychain.
struct IdentityRecord: Codable {
    var version: Int = 1
    var fid: FID
    var custodyAddress: String
    var signerPublicKeyHex: String
    var createdAt: Date
    var signerExpiresAt: Date?
}

// MARK: - Helpers

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        let text = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard text.count % 2 == 0 else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

extension Date {
    /// Farcaster epoch seconds: Unix time minus 1609459200.
    var farcasterEpoch: UInt32 {
        UInt32(max(0, Int(timeIntervalSince1970) - 1_609_459_200))
    }
}
