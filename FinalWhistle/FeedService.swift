import Foundation
import os

/// Public Hypersnap reads. No auth, no API key, HTTPS only.
/// Base: https://hypersnap.castrater.xyz
/// Verified live 20 Nov 2026:
///   GET /v2/farcaster/feed/channels?channel_ids=football&limit=20
///     -> {"casts": [...]} — every cast's parent_url is
///     https://farcaster.xyz/~/channel/football. This is the real
///     /football channel feed, not a keyword search.
///   GET /v2/farcaster/user?fid=<fid> -> {"user": {...}}
///   GET /v2/farcaster/user/by-username?username=<name> -> {"user": {"fid": ...}}
/// Do NOT use the for-you feed (it returns trending) or the cast summary
/// endpoint (it returns a placeholder string, the node has no LLM).
/// Note: the /football channel is quiet. At the 20 Nov 2026 check it
/// held 7 casts in total, newest 7 Nov 2026, so a sparse, old feed is
/// the channel itself, not a loading bug. The old keyword search
/// (q=football) was fresher but pulled in casts from everywhere; it is
/// gone by design. New top-level posts from the app carry parent_url
/// chain://eip155:1/erc721:0x7abfe142031532e1ad0e46f971cc0ef7cf4b98b0
/// (the channel's NFT-gated canonical URL), so they land in this feed.

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
        request.setValue("FinalWhistle-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try decoder().decode(T.self, from: data)
    }

    /// The whole feed is the /football channel. No trending tab, no
    /// keyword search: only casts posted into the channel.
    static func football(limit: Int = 20) async throws -> [Cast] {
        let response: ChannelFeedResponse = try await get("/v2/farcaster/feed/channels?channel_ids=football&limit=\(limit)")
        return dedup(response.casts).sorted { $0.timestamp > $1.timestamp }
    }

    static func user(fid: FID) async throws -> UserResponse.User {
        let response: UserResponse = try await get("/v2/farcaster/user?fid=\(fid.value)")
        return response.user
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

    enum LoadState: Equatable {
        case loading
        case loaded
        case empty
        case failed(String)
    }

    private let cache = LocalStore<[Cast]>(fileName: "feed-cache.json")

    init() {
        // Open at once with what is saved. Never block launch on the network.
        if let cached = try? cache.load(), !cached.isEmpty {
            casts = cached
            state = .loaded
        }
    }

    func refresh() async {
        state = .loading
        do {
            let fresh = try await FeedService.football()
            casts = fresh
            state = fresh.isEmpty ? .empty : .loaded
            try? cache.save(fresh)
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

    /// Optimistic local reaction count bump. The server count is the truth on
    /// the next refresh; this only makes the tap feel instant.
    func bumpReaction(for hash: String, like: Bool) {
        guard let index = casts.firstIndex(where: { $0.hash == hash }) else { return }
        var cast = casts[index]
        if like { cast.reactions.likesCount += 1 } else { cast.reactions.recastsCount += 1 }
        casts[index] = cast
    }
}
