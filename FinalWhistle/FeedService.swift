import Foundation
import os

/// Public Hypersnap reads. No auth, no API key, HTTPS only.
/// Base: https://hypersnap.castrater.xyz
/// Verified live 20 Nov 2026, following Quilcast
/// (github.com/backmeupplz/quilcast, MIT — server/index.mjs channelFeed,
/// src/app.tsx ChannelPage, src/api.ts urlOf/loadMine):
///   GET /v2/farcaster/feed/parent_urls?parent_urls=<channel url>&limit=50
///     -> {"casts": [...]} — the channel's casts under its REAL parent
///     URL. For /football that URL is the NFT address
///     chain://eip155:1/erc721:0x7abfe142031532e1ad0e46f971cc0ef7cf4b98b0.
///     At the 20 Nov check this returned 50 fresh casts, newest the
///     user's own "Test" post that day, then 19 Nov, 17 Nov, ... — the
///     live channel, with footy-app, kmacb.eth, kazani and others.
///   The old feed/channels?channel_ids=football endpoint returns a
///   DIFFERENT, dead bucket: only 7 casts, all with parent_url
///   https://farcaster.xyz/~/channel/football, newest 7 Nov 2026.
///   That is why the app showed a stale feed while posts (correctly
///   carrying the chain:// parent_url) never appeared in it. Do NOT
///   use feed/channels for this channel.
///   GET /v2/farcaster/user?fid=<fid> -> {"user": {...}}
///   GET /v2/farcaster/user/by-username?username=<name> -> {"user": {"fid": ...}}
///   GET /v2/farcaster/cast/conversation?identifier=<hash>&type=hash
///     -> {"conversation": {"cast": {..., "direct_replies": [...]}}}
///     (direct_replies live INSIDE the cast, not at the top level).
///   GET /v1/reactionsByFid?fid=<fid>&reaction_type=Like|Recast
///     -> {"messages": [{"data": {"reactionBody": {"targetCastId":
///        {"hash": "0x..."}}}}]} — what the viewer already liked/recast.
///   Pass viewer_fid on /v2 reads when signed in: the node then answers
///   viewer_context {liked, recasted} on every cast (Hypersnap PR #43).
/// Do NOT use the for-you feed (it returns trending) or the cast summary
/// endpoint (it returns a placeholder string, the node has no LLM).

struct FeedService {
    static let baseURL = URL(string: "https://hypersnap.castrater.xyz")!
    static let grpcHost = "grpc.castrater.xyz"
    static let grpcPort = 3383

    private static let logger = Logger(subsystem: "app.final-whistle", category: "feed")

    /// Timestamps arrive as ISO strings with fractional seconds
    /// ("2026-11-19T15:57:48.000Z"). Plain .iso8601 decoding rejects the
    /// fractional form on some OS versions, so try it first, then the
    /// form without fractional seconds.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not an ISO-8601 date: \(text)"
            )
        }
        return decoder
    }

    private static func decoder() -> JSONDecoder { makeDecoder() }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // A refresh must hit the network, not a cached response: the
        // default protocol cache policy can serve a stale feed and make
        // pull-to-refresh look like it did nothing.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("FinalWhistle-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder().decode(T.self, from: data)
    }

    /// Casts posted under one parent URL (Quilcast's feed/parent_urls,
    /// not feed/channels). The /football channel is one such parent URL;
    /// the live match rooms are others (final-whistle.app/chat/<n>).
    static func parentURL(_ parentURL: String, limit: Int = 50, viewerFID: FID? = nil) async throws -> [Cast] {
        // Percent-encode the parent URL strictly: ":" and "/" must not
        // survive inside a query value.
        let strict = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = parentURL.addingPercentEncoding(withAllowedCharacters: strict) else {
            throw URLError(.badURL)
        }
        var path = "/v2/farcaster/feed/parent_urls?parent_urls=\(encoded)&limit=\(limit)"
        if let viewerFID { path += "&viewer_fid=\(viewerFID.value)" }
        let response: ChannelFeedResponse = try await get(path)
        return dedup(response.casts).sorted { $0.timestamp > $1.timestamp }
    }

    /// The whole feed is the /football channel. No trending tab, no
    /// keyword search: only casts posted into the channel, under its
    /// real parent URL.
    static func football(limit: Int = 50, viewerFID: FID? = nil) async throws -> [Cast] {
        try await parentURL(FarcasterMessages.footballChannelURL, limit: limit, viewerFID: viewerFID)
    }

    /// One cast plus its direct replies, for the thread view.
    static func conversation(hash: String, viewerFID: FID? = nil) async throws -> Cast {
        var path = "/v2/farcaster/cast/conversation?identifier=\(hash)&type=hash"
        if let viewerFID { path += "&viewer_fid=\(viewerFID.value)" }
        let response: ConversationResponse = try await get(path)
        return response.conversation.cast
    }

    /// Hashes (bare hex, lowercased) the FID already liked or recast,
    /// newest first (Quilcast's loadMine). Used to fill the like/recast
    /// buttons on launch, since a fresh feed may not carry viewer_context.
    static func reactionsByFid(fid: FID, type: String) async throws -> Set<String> {
        struct Response: Decodable {
            struct Message: Decodable {
                struct Data: Decodable {
                    struct ReactionBody: Decodable {
                        struct TargetCastId: Decodable { let hash: String }
                        let targetCastId: TargetCastId?
                    }
                    let reactionBody: ReactionBody?
                }
                let data: Data?
            }
            let messages: [Message]
        }
        let response: Response = try await get("/v1/reactionsByFid?fid=\(fid.value)&reaction_type=\(type)&pageSize=200&reverse=true")
        var out = Set<String>()
        for message in response.messages {
            if let hash = message.data?.reactionBody?.targetCastId?.hash {
                out.insert(hash.replacingOccurrences(of: "0x", with: "").lowercased())
            }
        }
        return out
    }

    static func user(fid: FID) async throws -> UserResponse.User {
        let response: UserResponse = try await get("/v2/farcaster/user?fid=\(fid.value)")
        return response.user
    }

    /// A user's recent casts, newest first (Quilcast app.tsx userCasts:
    /// /v2/farcaster/feed/user/casts?fid=&limit=25). Used by the profile
    /// page a mention tap opens.
    // RESTORED 2026-11-20: the Rooms commit (16fb9ca) wiped this — it
    // was edited from a local copy that predated the other chat's
    // 80e5eda addition. Never edit FeedService from a stale local copy;
    // fetch the remote file first.
    static func userCasts(fid: FID, limit: Int = 25) async throws -> [Cast] {
        struct Response: Decodable { let casts: [Cast] }
        let response: Response = try await get("/v2/farcaster/feed/user/casts?fid=\(fid.value)&limit=\(limit)")
        return response.casts
    }

    static func userCast(hash: String) async throws -> Cast {
        // Response shape is {"cast": {...}} on the Neynar-compatible read
        // API; fall back to a bare cast object if a node returns that.
        struct Wrapped: Codable { let cast: Cast }
        guard let url = URL(string: "/v2/farcaster/cast?identifier=0x\(hash)&type=hash", relativeTo: baseURL) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let wrapped = try? decoder().decode(Wrapped.self, from: data) { return wrapped.cast }
        return try decoder().decode(Cast.self, from: data)
    }

    static func fid(forUsername username: String) async throws -> FID? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !name.isEmpty,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        do {
            let response: UsernameLookupResponse = try await get("/v2/farcaster/user/by-username?username=\(encoded)")
            return response.user.fid
        } catch {
            logger.info("username lookup failed for \(name): \(error.localizedDescription)")
            return nil
        }
    }

    static func dedup(_ casts: [Cast]) -> [Cast] {
        var seen = Set<String>()
        return casts.filter { seen.insert($0.hash).inserted }
    }
}

// MARK: - Feed store (UI state)

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var casts: [Cast] = []
    @Published private(set) var state: LoadState = .loading
    /// Hashes (bare hex, lowercased) this viewer liked / quoted-reposted.
    /// Source of truth for the filled heart and the coloured quote button.
    /// Merged from viewer_context on each cast and from reactionsByFid
    /// (Quilcast's mine), and kept across launches in LocalStore.
    @Published private(set) var likedHashes: Set<String> = []
    @Published private(set) var quotedHashes: Set<String> = []
    /// Hashes the user toggled this session: a refresh must not undo a
    /// tap the server has not caught up with yet (Quilcast's taps map).
    private var tappedThisSession: Set<String> = []
    private var mineLoadedForFID: UInt64?

    enum LoadState: Equatable {
        case loading
        case loaded
        case empty
        case failed(String)
    }

    private let cache = LocalStore<[Cast]>(fileName: "feed-cache.json")
    private let likedStore = LocalStore<Set<String>>(fileName: "liked-hashes.json")
    private let quotedStore = LocalStore<Set<String>>(fileName: "quoted-hashes.json")

    init() {
        // Open at once with what is saved. Never block launch on the network.
        if let cached = try? cache.load(), !cached.isEmpty {
            casts = cached
            state = .loaded
        }
        likedHashes = (try? likedStore.load()) ?? []
        quotedHashes = (try? quotedStore.load()) ?? []
    }

    func refresh(viewerFID: FID? = nil) async {
        state = .loading
        if let viewerFID, mineLoadedForFID != viewerFID.value {
            await loadViewerState(fid: viewerFID)
        }
        do {
            let fresh = try await FeedService.football(viewerFID: viewerFID)
            casts = fresh
            state = fresh.isEmpty ? .empty : .loaded
            try? cache.save(fresh)
            mergeViewerContext()
        } catch {
            if casts.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                // Keep the cached feed visible and surface the error in the UI
                // via the state only when there is nothing to show.
                state = .loaded
            }
        }
    }

    /// Load what the viewer already liked/recast from the node, once per FID.
    func loadViewerState(fid: FID) async {
        mineLoadedForFID = fid.value
        do {
            let likes = try await FeedService.reactionsByFid(fid: fid, type: "Like")
            likedHashes.formUnion(likes)
            try? likedStore.save(likedHashes)
        } catch {
            // Buttons just stay unfilled; the tap still works.
        }
    }

    /// Fold each cast's viewer_context into the sets, except for hashes
    /// the user toggled this session (the server may lag the tap).
    private func mergeViewerContext() {
        for cast in casts {
            let key = cast.hash.lowercased()
            guard !tappedThisSession.contains(key), let ctx = cast.viewerContext else { continue }
            if ctx.liked { likedHashes.insert(key) } else { likedHashes.remove(key) }
        }
        try? likedStore.save(likedHashes)
    }

    func isLiked(_ cast: Cast) -> Bool { likedHashes.contains(cast.hash.lowercased()) }
    func isQuoted(_ cast: Cast) -> Bool { quotedHashes.contains(cast.hash.lowercased()) }

    /// The like count to show: the server count, adjusted for a tap the
    /// server count does not include yet (Quilcast's tapped()).
    func likesCount(for cast: Cast) -> Int {
        let base = cast.reactions.likesCount
        let serverSaysLiked = cast.viewerContext?.liked ?? false
        if isLiked(cast) && !serverSaysLiked { return base + 1 }
        if !isLiked(cast) && serverSaysLiked { return max(0, base - 1) }
        return base
    }

    /// Optimistic like toggle. Returns true when the tap should be sent
    /// to the node (like), false when it should be removed (unlike).
    /// The caller reverts on failure via setLiked.
    func toggleLike(_ cast: Cast) -> Bool {
        let key = cast.hash.lowercased()
        tappedThisSession.insert(key)
        if likedHashes.contains(key) {
            likedHashes.remove(key)
            try? likedStore.save(likedHashes)
            return false
        }
        likedHashes.insert(key)
        try? likedStore.save(likedHashes)
        return true
    }

    func setLiked(_ cast: Cast, liked: Bool) {
        let key = cast.hash.lowercased()
        if liked { likedHashes.insert(key) } else { likedHashes.remove(key) }
        try? likedStore.save(likedHashes)
    }

    func markQuoted(_ cast: Cast) {
        quotedHashes.insert(cast.hash.lowercased())
        try? quotedStore.save(quotedHashes)
    }
}
