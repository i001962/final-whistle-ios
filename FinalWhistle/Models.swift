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

/// What the signed-in viewer did to a cast, when the node was asked with
/// viewer_fid (Quilcast's api.ts: nodes with Hypersnap PR #43 answer this
/// on every /v2 cast). Without viewer_fid the field is absent.
struct ViewerContext: Codable, Hashable {
    var liked: Bool = false
    var recasted: Bool = false

    enum CodingKeys: String, CodingKey { case liked, recasted }

    init(liked: Bool = false, recasted: Bool = false) {
        self.liked = liked
        self.recasted = recasted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liked = try container.decodeIfPresent(Bool.self, forKey: .liked) ?? false
        recasted = try container.decodeIfPresent(Bool.self, forKey: .recasted) ?? false
    }
}

/// One embed on a cast: a link URL, or a quoted cast (cast_id).
/// Quilcast's write.ts builds a quoted cast as Embed field 2 = cast_id.
struct CastEmbed: Codable, Hashable {
    let url: String?
    let castID: CastIDRef?

    struct CastIDRef: Codable, Hashable {
        let fid: FID
        let hash: String
    }

    enum CodingKeys: String, CodingKey {
        case url
        case castID = "cast_id"
    }
}

/// One cast from the public read API. The hash is hex without a 0x prefix.
/// direct_replies is only filled by the conversation endpoint; embeds
/// carry quoted casts; viewer_context only when asked with viewer_fid.
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
    var viewerContext: ViewerContext?
    var directReplies: [Cast]?
    let embeds: [CastEmbed]?

    var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, text, timestamp, author, reactions, replies, embeds
        case parentHash = "parent_hash"
        case parentAuthor = "parent_author"
        case threadHash = "thread_hash"
        case viewerContext = "viewer_context"
        case directReplies = "direct_replies"
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
        viewerContext = try container.decodeIfPresent(ViewerContext.self, forKey: .viewerContext)
        directReplies = try container.decodeIfPresent([Cast].self, forKey: .directReplies)
        embeds = try container.decodeIfPresent([CastEmbed].self, forKey: .embeds)
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
        try container.encodeIfPresent(viewerContext, forKey: .viewerContext)
        try container.encodeIfPresent(directReplies, forKey: .directReplies)
        try container.encodeIfPresent(embeds, forKey: .embeds)
    }
}

/// The conversation endpoint: {"conversation": {"cast": {...}}} where the
/// cast carries direct_replies (each with its own direct_replies).
struct ConversationResponse: Codable {
    struct Conversation: Codable {
        let cast: Cast
    }
    let conversation: Conversation
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
