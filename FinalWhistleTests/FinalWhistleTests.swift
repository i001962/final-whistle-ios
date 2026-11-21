import XCTest
@testable import FinalWhistle

/// Unit tests for core logic and saving. These were written without Xcode
/// on a Linux machine and have NOT been run yet: run them on the Mac with
///   xcodebuild test -scheme FinalWhistle -destination 'platform=iOS Simulator,name=NAME' -derivedDataPath DerivedData.noindex
/// The vectors below are byte-exact against the Python reference
/// (eth-account / eth-abi / blake3 / protobuf), computed 19 Nov 2026.
/// Test key 0x1111... is a throwaway test vector only, never a real key.
final class FinalWhistleTests: XCTestCase {

    // MARK: - BLAKE3

    func testBlake3EmptyVector() {
        XCTAssertEqual(
            Blake3.hash(Data()).hexString,
            "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262"
        )
    }

    func testBlake3HelloVector() {
        XCTAssertEqual(
            Blake3.hash(Data("hello".utf8)).hexString,
            "ea8f163db38682925e4491c5e58d4bb3506ef8c14eb78a86e908c5624a67200f"
        )
    }

    // MARK: - Protobuf (vectors from the Python protobuf library)

    func testCastAddBodyBytes() {
        let body = FarcasterMessages.castAddBody(
            text: " hello", mentions: [4163, 999], mentionPositions: [0, 6],
            parentAuthorFID: nil, parentHash: nil
        )
        XCTAssertEqual(body.hexString, "1204c320e70722062068656c6c6f2a020006")
    }

    func testCastAddBodyParentURL() {
        // A top-level post into /football carries parent_url (field 7).
        // Without it the cast goes to the global feed, not the channel.
        let body = FarcasterMessages.castAddBody(
            text: " hi", mentions: [], mentionPositions: [],
            parentAuthorFID: nil, parentHash: nil,
            parentURL: FarcasterMessages.footballChannelURL
        )
        let url = Data(FarcasterMessages.footballChannelURL.utf8)
        var expected = Data()
        expected.append(contentsOf: [0x22, 0x03, 0x20, 0x68, 0x69]) // text " hi"
        expected.append(contentsOf: [0x3a, UInt8(url.count)]) // parent_url, field 7
        expected.append(url)
        XCTAssertEqual(body.hexString, expected.hexString)
    }

    func testCastAddBodyQuoteEmbed() {
        // A quoted repost carries the quoted cast as Embed field 6, with
        // the cast_id inside as Embed field 2 (Quilcast's fc.ts castBody).
        let hash = Data(repeating: 0x11, count: 20)
        let body = FarcasterMessages.castAddBody(
            text: " hi", mentions: [], mentionPositions: [],
            parentAuthorFID: nil, parentHash: nil,
            parentURL: FarcasterMessages.footballChannelURL,
            quotedCasts: [(fid: 4163, hash: hash)]
        )
        // cast_id: fid 4163 varint (0x08 0xc3 0x20), hash bytes (0x12 0x14 + 20 bytes)
        var castId = Data()
        castId.append(contentsOf: [0x08, 0xc3, 0x20, 0x12, 0x14])
        castId.append(hash)
        // embed: field 2, length of cast_id
        var embed = Data()
        embed.append(contentsOf: [0x12, UInt8(castId.count)])
        embed.append(castId)
        XCTAssertTrue(body.hexString.contains(embed.hexString))
        // and the channel parent_url (field 7) is still there
        XCTAssertTrue(body.hexString.contains(FarcasterMessages.footballChannelURL.utf8.map { String(format: "%02x", $0) }.joined()))
    }

    func testCastAddBodyImageEmbed() {
        // A picture embed is Embed field 6, with the URL inside as
        // Embed field 1 (Quilcast's fc.ts castBody). A sticker goes out
        // as one of these with no text.
        let url = "https://final-whistle.app/st/abcdefgh/0123456789abcdef01234567.webp"
        let body = FarcasterMessages.castAddBody(
            text: "", mentions: [], mentionPositions: [],
            parentAuthorFID: nil, parentHash: nil,
            parentURL: FarcasterMessages.footballChannelURL,
            imageURLs: [url]
        )
        let urlBytes = Array(url.utf8)
        var embed = Data()
        embed.append(contentsOf: [0x0A, UInt8(urlBytes.count)])
        embed.append(contentsOf: urlBytes)
        var field = Data()
        field.append(contentsOf: [0x32, UInt8(embed.count)])
        field.append(embed)
        XCTAssertTrue(body.hexString.contains(field.hexString))
    }

    func testImageCacheRoundTrip() {
        // A stored pfp comes back from the cache, so a scrolling list
        // never re-fetches a picture it already has.
        let url = URL(string: "https://example.com/pfp.png")!
        let image = UIImage(systemName: "star")!
        ImageCache.shared.set(image, for: url)
        XCTAssertNotNil(ImageCache.shared.image(for: url))
        XCTAssertNil(ImageCache.shared.image(for: URL(string: "https://example.com/other.png")!))
    }

    func testStickerURLPattern() {
        // Hosted-pack shape, Quilcast's stickerPack check with our host.
        let hosted = URL(string: "https://final-whistle.app/st/abcdefgh/0123456789abcdef01234567.webp")!
        XCTAssertTrue(StickerStore.shared.isSticker(hosted))
        let photo = URL(string: "https://example.com/photo.jpg")!
        XCTAssertFalse(StickerStore.shared.isSticker(photo))
        // And a pack member counts even off our host.
        XCTAssertTrue(StickerStore.shared.addSticker(url: "https://example.com/sticker.png"))
        XCTAssertTrue(StickerStore.shared.isSticker(URL(string: "https://example.com/sticker.png")!))
    }

    func testFeedDecodesViewerContextAndEmbeds() throws {
        let json = """
        {"casts": [{"object": "cast", "hash": "aa", "text": "quoted", "timestamp": "2026-11-20T19:17:43.000Z",
        "author": {"fid": 4294967327, "username": "fid:4294967327"},
        "reactions": {"likes_count": 2, "recasts_count": 1}, "replies": {"count": 1},
        "viewer_context": {"liked": true, "recasted": false},
        "embeds": [{"cast_id": {"fid": 4163, "hash": "bb"}}],
        "direct_replies": [{"hash": "cc", "text": "reply", "timestamp": "2026-11-20T19:20:00.000Z",
        "author": {"fid": 4163, "username": "kmacb.eth"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0}}]}]}
        """.data(using: .utf8)!
        let feed = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json)
        let cast = feed.casts[0]
        XCTAssertEqual(cast.viewerContext?.liked, true)
        XCTAssertEqual(cast.embeds?.first?.castID?.fid.value, 4163)
        XCTAssertEqual(cast.embeds?.first?.castID?.hash, "bb")
        XCTAssertEqual(cast.directReplies?.count, 1)
        XCTAssertEqual(cast.directReplies?.first?.author.displayUsername, "kmacb.eth")
    }

    func testFeedDecodesQuoteEmbedAndMentions() throws {
        // The exact shape of the user's quote repost in the live
        // parent_urls feed: a cast_id embed plus a mention whose range
        // is empty (the name is stripped from the stored text).
        let json = """
        {"casts": [{"hash": "048b548f", "text": "Scout brings back memories of ’s project back in the day scouting devs",
        "timestamp": "2026-11-20T19:59:05.000Z",
        "author": {"fid": 4294967327, "username": "fid:4294967327"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0},
        "embeds": [{"cast_id": {"fid": 318845, "hash": "f6deaf70d838885e51857c91a020287ce11f2647"}}],
        "mentioned_profiles": [{"fid": 472, "username": "ccarella"}],
        "mentioned_profiles_ranges": [{"start": 30, "end": 30}]}]}
        """.data(using: .utf8)!
        let feed = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json)
        let cast = feed.casts[0]
        XCTAssertEqual(cast.embeds?.first?.castID?.fid.value, 318845)
        XCTAssertEqual(cast.embeds?.first?.castID?.hash, "f6deaf70d838885e51857c91a020287ce11f2647")
    }

    func testYouTubeRSSParsesEntries() {
        // The exact shape of the @split-peel channel feed:
        // https://www.youtube.com/feeds/videos.xml?channel_id=UCQn56wvJDa4ukd5n8XF5z_A
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/" xmlns:yt="http://www.youtube.com/xml/schemas/2015">
        <title>Final Whistle with Split &amp; Peel</title>
        <entry><yt:videoId>MlTgU-gZY8I</yt:videoId><title>Arsenal's FPL Leak</title>
        <published>2026-11-20T15:04:49+00:00</published>
        <media:group><media:thumbnail url="https://i2.ytimg.com/vi/MlTgU-gZY8I/hqdefault.jpg"/>
        <media:description>Episode one.</media:description></media:group></entry>
        <entry><yt:videoId>A4Uf8GOg-Kk</yt:videoId><title>Pochettino Has Three Days</title>
        <published>2026-11-19T15:02:00+00:00</published>
        <media:group><media:thumbnail url="https://i2.ytimg.com/vi/A4Uf8GOg-Kk/hqdefault.jpg"/>
        <media:description>Episode two.</media:description></media:group></entry>
        </feed>
        """.data(using: .utf8)!
        let videos = YouTubeService.parse(data: xml)
        XCTAssertEqual(videos.count, 2)
        XCTAssertEqual(videos[0].id, "MlTgU-gZY8I")
        XCTAssertEqual(videos[0].title, "Arsenal's FPL Leak")
        XCTAssertEqual(videos[0].thumbnailURL?.absoluteString, "https://i2.ytimg.com/vi/MlTgU-gZY8I/hqdefault.jpg")
        XCTAssertEqual(videos[0].summary, "Episode one.")
        XCTAssertEqual(videos[0].watchURL.absoluteString, "https://www.youtube.com/watch?v=MlTgU-gZY8I")
        XCTAssertNotNil(videos[0].published)
        XCTAssertEqual(videos[1].id, "A4Uf8GOg-Kk")
    }

    func testReactionBodyBytes() {
        let data = FarcasterMessages.reactionData(
            fid: 4294967310, timestamp: 123456, reactionType: 1,
            targetAuthorFID: 8106, targetHash: Data(hex: "0af1897505c73ec1ae58cd43c0b59b95a8ac0c61")!,
            remove: false
        )
        // MessageData: type 3, fid, timestamp, network 1, reaction_body field 7.
        // ReactionBody is 29 bytes (0x1d), not 25: type + target_cast_id (25 bytes).
        XCTAssertEqual(
            data.hexString,
            "0803108e8080801018c0c40720013a1d0801121908aa3f12140af1897505c73ec1ae58cd43c0b59b95a8ac0c61"
        )
    }

    func testMessageDataOmitsZeroFID() {
        // NativeOnboard uses fid 0, which proto3 omits.
        let data = FarcasterMessages.nativeOnboardData(
            timestamp: 100, custody: Data(repeating: 0x11, count: 20),
            custodySignature: Data(repeating: 0x22, count: 65),
            anchorHeight: 100, anchorHash: Data(repeating: 0x33, count: 32),
            nonce: 1, difficultyBits: 22
        )
        XCTAssertTrue(data.hexString.hasPrefix("08a001"))
        // The next field must be the timestamp (field 3, tag 0x18), not
        // the fid field (field 2, tag 0x10): fid 0 is omitted.
        XCTAssertTrue(data.hexString.hasPrefix("08a0011864"))
    }

    // MARK: - Mentions

    func testMentionEncoding() {
        let (stored, fids, positions) = FarcasterMessages.encodeMentions(
            displayText: "@kmacb.eth hello Hypersnap",
            mentions: [("kmacb.eth", 4163)]
        )
        XCTAssertEqual(stored, " hello Hypersnap")
        XCTAssertEqual(fids, [4163])
        XCTAssertEqual(positions, [0])
    }

    func testMentionTokens() {
        XCTAssertEqual(
            FarcasterMessages.mentionTokens(in: "hi @peel and @kmacb.eth!"),
            ["peel", "kmacb.eth"]
        )
    }

    func testMentionSplicedBackIntoText() throws {
        // The live 048b548f vector (see testFeedDecodesQuoteEmbedAndMentions):
        // the stored text strips @ccarella and the range (30, 30) says
        // where it goes back (Quilcast shared.ts castText).
        let json = """
        {"casts": [{"hash": "048b548f", "text": "Scout brings back memories of ’s project back in the day scouting devs",
        "timestamp": "2026-11-20T19:59:05.000Z",
        "author": {"fid": 4294967327, "username": "fid:4294967327"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0},
        "embeds": [{"cast_id": {"fid": 318845, "hash": "f6deaf70d838885e51857c91a020287ce11f2647"}}],
        "mentioned_profiles": [{"fid": 472, "username": "ccarella"}],
        "mentioned_profiles_ranges": [{"start": 30, "end": 30}]}]}
        """.data(using: .utf8)!
        let cast = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json).casts[0]
        XCTAssertTrue(cast.textSegments.contains(.mention(fid: FID(472), username: "ccarella")))
        XCTAssertEqual(
            String(cast.attributedText().characters),
            "Scout brings back memories of @ccarella’s project back in the day scouting devs"
        )
    }

    func testMentionOffsetIsBytesNotCharacters() throws {
        // ⚽ is 3 UTF-8 bytes but 1 character: a character offset would
        // splice the mention a byte too early ("Hi ⚽  @aliceteam").
        let json = """
        {"casts": [{"hash": "zz", "text": "Hi ⚽  team",
        "timestamp": "2026-11-20T19:59:05.000Z",
        "author": {"fid": 1, "username": "a"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0},
        "mentioned_profiles": [{"fid": 99, "username": "alice"}],
        "mentioned_profiles_ranges": [{"start": 7, "end": 7}]}]}
        """.data(using: .utf8)!
        let cast = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json).casts[0]
        XCTAssertEqual(String(cast.attributedText().characters), "Hi ⚽ @alice team")
    }

    func testBareLinkInTextIsALinkSegment() throws {
        let json = """
        {"casts": [{"hash": "yy", "text": "watch https://youtu.be/A4Uf8GOg-Kk now",
        "timestamp": "2026-11-20T19:59:05.000Z",
        "author": {"fid": 1, "username": "a"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0}}]}
        """.data(using: .utf8)!
        let cast = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json).casts[0]
        XCTAssertTrue(cast.textSegments.contains(
            .link(url: URL(string: "https://youtu.be/A4Uf8GOg-Kk")!, display: "youtu.be/A4Uf8GOg-Kk")
        ))
    }

    // MARK: - Embeds

    func testEmbedClassification() {
        XCTAssertTrue(CastMedia.isImageURL(URL(string: "https://imagedelivery.net/abc/def/original")!))
        XCTAssertTrue(CastMedia.isImageURL(URL(string: "https://example.com/pic.png")!))
        XCTAssertFalse(CastMedia.isImageURL(URL(string: "https://youtu.be/A4Uf8GOg-Kk")!))
        XCTAssertTrue(CastMedia.isVideoURL(URL(string: "https://example.com/v.mp4")!))
        XCTAssertFalse(CastMedia.isVideoURL(URL(string: "https://example.com/pic.png")!))
        // Farcaster's image CDN resizes on request (Quilcast sized).
        XCTAssertEqual(
            CastMedia.sizedImageURL(URL(string: "https://imagedelivery.net/abc/def/original")!).absoluteString,
            "https://imagedelivery.net/abc/def/w=1200"
        )
        XCTAssertEqual(
            CastMedia.sizedImageURL(URL(string: "https://example.com/pic.png")!).absoluteString,
            "https://example.com/pic.png"
        )
    }

    func testEmbedURLsSkipLinksAlreadyInText() throws {
        // A YouTube link pasted in the text AND embedded shows once (as a
        // tappable link in the text), not twice (link + card) — Quilcast urlsOf.
        let json = """
        {"casts": [{"hash": "xx", "text": "watch https://youtu.be/A4Uf8GOg-Kk",
        "timestamp": "2026-11-20T19:59:05.000Z",
        "author": {"fid": 1, "username": "a"},
        "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0},
        "embeds": [{"url": "https://youtu.be/A4Uf8GOg-Kk"}, {"url": "https://imagedelivery.net/abc/def/original"}]}]}
        """.data(using: .utf8)!
        let cast = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json).casts[0]
        XCTAssertEqual(cast.linkEmbedURLs, [])
        XCTAssertEqual(cast.imageEmbedURLs.map(\.absoluteString), ["https://imagedelivery.net/abc/def/original"])
    }

    // MARK: - PoW

    func testPowHashAndTarget() {
        let custody = Data(hex: "19e7e376e7c213b7e7e7e46cc70a5dd086daff2a")!
        let anchor = Data(repeating: 0x22, count: 32)
        let hash = FarcasterMessages.powHash(custody: custody, anchor: anchor, nonce: 0)
        XCTAssertEqual(hash.count, 32)
        // 22-bit target: first two bytes zero, third byte below 4.
        XCTAssertTrue(FarcasterMessages.powTargetMet(hash: Data([0, 0, 3]), bits: 22))
        XCTAssertFalse(FarcasterMessages.powTargetMet(hash: Data([0, 0, 4]), bits: 22))
        XCTAssertFalse(FarcasterMessages.powTargetMet(hash: Data([0, 1, 0]), bits: 22))
    }

    func testGateCommitmentLength() {
        let commitment = FarcasterMessages.gateCommitment(nonce: 12345, difficultyBits: 22)
        XCTAssertEqual(commitment.hexString, "ee65223b6cf6b5a184dbff0acabf89ee0c20c3cea2a6d98ca250c8b9deb5e7e1")
    }

    // MARK: - EIP-712 (vectors from eth-account, test key 0x1111...)

    private let testCustody = "0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A"
    private let testPrivateKey = Data(repeating: 0x11, count: 32)

    func testHyperNativeOnboardDigestAndSignature() throws {
        let anchor = Data(repeating: 0x22, count: 32)
        let commitment = FarcasterMessages.gateCommitment(nonce: 12345, difficultyBits: 22)
        let structHash = Ethereum.hyperNativeOnboardStructHash(
            custody: testCustody, anchorHeight: 100, anchorHash: anchor, gateCommitment: commitment
        )
        let separator = Ethereum.domainSeparator(name: "HypersnapNativeOnboard", version: "1", chainId: 10)
        let digest = Ethereum.eip712Hash(domainSeparator: separator, structHash: structHash)
        XCTAssertEqual(digest.hexString, "8467bacd1d28728d35d333e577dbf240606ef94c5c52a2899b7f0c49aa2716ad")
        let signature = try CustodyKeys.signEIP712(
            domainName: "HypersnapNativeOnboard", domainVersion: "1", chainId: 10,
            structHash: structHash, privateKey: testPrivateKey
        )
        // eth-account reference signature for the same digest and key.
        XCTAssertEqual(
            signature.hexString,
            "319a0aad414f51eab098c6ecfdb1dac51e19342e6ae7f8b7c19d9f8b24029c5045d253ed3d32be6bd3947c009442da08762588130608bc5babd690345cfc988b1b"
        )
    }

    func testKeyAddDigestAndSignature() throws {
        let signerPublicKey = Data(repeating: 0x33, count: 32)
        let structHash = Ethereum.keyAddStructHash(
            fid: 4294967310, key: signerPublicKey, keyType: 1,
            scopes: [1, 2, 3, 4, 5, 6, 11, 12], ttl: 2592000, nonce: 1, deadline: 1700000000
        )
        let separator = Ethereum.domainSeparator(name: "Farcaster KeyAdd", version: "1", chainId: 1)
        let digest = Ethereum.eip712Hash(domainSeparator: separator, structHash: structHash)
        XCTAssertEqual(digest.hexString, "0321d8543b8de9b6d24033f20d0ca446a246b6ccd55dcaffcf595a8ea6f739cb")
        let signature = try CustodyKeys.signEIP712(
            domainName: "Farcaster KeyAdd", domainVersion: "1", chainId: 1,
            structHash: structHash, privateKey: testPrivateKey
        )
        XCTAssertEqual(
            signature.hexString,
            "3da203fb1e2c552f56111b56fb29cbdc74259a83f5876c2a6ec54f363880fca819eeaa88226b9d8548b83cf1ac5b27f6a948a75bba9338dc37f18d35a8f842121c"
        )
    }

    func testSignedKeyRequestMetadataBytes() throws {
        // SignedKeyRequest signature from eth-account for the same inputs.
        let skrSignature = Data(hex: "59502ba55daee3d496f3d8f01abd6b5e0a24d9ab2f280ee1f0bbd7f28db3b76b62efa7cd0a705002b611e30999fe03d2c6c7f4d29402585382acc4b6422d7d611b")!
        let metadata = FarcasterMessages.signedKeyRequestMetadata(
            requestFid: 4294967310, requestSigner: testCustody,
            signature: skrSignature, deadline: 1700000000
        )
        XCTAssertEqual(metadata.count, 288)
        XCTAssertEqual(
            metadata.hexString,
            "0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000010000000e00000000000000000000000019e7e376e7c213b7e7e7e46cc70a5dd086daff2a0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000006553f100000000000000000000000000000000000000000000000000000000000000004159502ba55daee3d496f3d8f01abd6b5e0a24d9ab2f280ee1f0bbd7f28db3b76b62efa7cd0a705002b611e30999fe03d2c6c7f4d29402585382acc4b6422d7d611b00000000000000000000000000000000000000000000000000000000000000"
        )
    }

    func testCustodyAddress() throws {
        XCTAssertEqual(try CustodyKeys.address(privateKey: testPrivateKey), testCustody)
    }

    func testLowSNormalisation() {
        // s just above n/2 must flip to n - s with the recovery id flipped.
        let highS = Data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140")!
        let (lowS, recoveryId) = Ethereum.normaliseLowS(s: highS, recoveryId: 0)
        XCTAssertEqual(recoveryId, 1)
        XCTAssertTrue(lowS.lexicographicallyPrecedes(Data(Ethereum.curveOrderHalf)) || lowS == Data(Ethereum.curveOrderHalf))
        // s below n/2 is unchanged.
        let low = Data(repeating: 0x01, count: 32)
        let (same, sameId) = Ethereum.normaliseLowS(s: low, recoveryId: 1)
        XCTAssertEqual(same, low)
        XCTAssertEqual(sameId, 1)
    }

    // MARK: - Feed JSON (live shape, captured 19 Nov 2026)

    func testFeedDecoding() throws {
        let json = """
        {"casts": [{"object": "cast", "hash": "0af1897505c73ec1ae58cd43c0b59b95a8ac0c61",
        "author": {"object": "user", "fid": 8106, "username": "project7", "display_name": "Project7",
        "pfp_url": "https://example.com/pfp.png", "follower_count": 17261, "following_count": 1235},
        "text": "Hello", "timestamp": "2026-11-19T15:57:48.000Z",
        "reactions": {"likes_count": 165, "recasts_count": 27},
        "replies": {"count": 157}, "thread_hash": "0af1897505c73ec1ae58cd43c0b59b95a8ac0c61"}]}
        """.data(using: .utf8)!
        let feed = try FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json)
        XCTAssertEqual(feed.casts.count, 1)
        XCTAssertEqual(feed.casts[0].author.fid.value, 8106)
        XCTAssertEqual(feed.casts[0].reactions.likesCount, 165)
        XCTAssertEqual(feed.casts[0].replies.count, 157)
    }

    func testFIDDecodesFromStringToo() throws {
        // The user endpoint carries fid as a string: "4294967310".
        let json = """
        {"user": {"fid": "4294967310", "username": "fid:4294967310", "display_name": "Peel",
        "custody_address": "0x51d27b0ec420290a395fa3a7880eaa8540a3e0df"}}
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(UserResponse.self, from: json)
        XCTAssertEqual(user.user.fid.value, 4294967310)
        XCTAssertTrue(user.user.fid.isNative)
    }

    func testFeedDedup() {
        let json = """
        {"casts": [{"hash": "aa", "text": "one", "timestamp": "2026-11-19T15:57:48.000Z",
        "author": {"fid": 1, "username": "a"}, "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0}},
        {"hash": "aa", "text": "one again", "timestamp": "2026-11-19T15:57:48.000Z",
        "author": {"fid": 1, "username": "a"}, "reactions": {"likes_count": 0, "recasts_count": 0}, "replies": {"count": 0}}]}
        """.data(using: .utf8)!
        let feed = try! FeedService.makeDecoder().decode(TrendingFeedResponse.self, from: json)
        XCTAssertEqual(FeedService.dedup(feed.casts).count, 1)
    }

    // MARK: - Local store

    func testLocalStoreRoundTripAndBackup() throws {
        let store = LocalStore<IdentityRecord>(fileName: "test-identity.json")
        let record = IdentityRecord(
            fid: FID(4294967310), custodyAddress: "0xabc", signerPublicKeyHex: "00ff",
            createdAt: Date(timeIntervalSince1970: 0), signerExpiresAt: nil
        )
        try store.save(record)
        let loaded = try store.load()
        XCTAssertEqual(loaded.fid, record.fid)
        XCTAssertEqual(loaded.custodyAddress, "0xabc")
        store.delete()
    }

    // MARK: - Profile photo upload

    func testPFPSignatureMessage() {
        let message = ProfilePhotoService.signatureMessage(fid: 4294967327, sha256Hex: "ab12")
        XCTAssertEqual(String(decoding: message, as: UTF8.self), "final-whistle-pfp:4294967327:ab12")
    }

    func testProfilePhotoMultipartBody() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let body = ProfilePhotoService.pfpMultipartBody(
            jpeg: jpeg, fid: 4294967327, signerPublicKeyHex: "11aa",
            sha256Hex: "ab12", signatureHex: "cc34", boundary: "fw-test"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"fid\"\r\n\r\n4294967327\r\n"))
        XCTAssertTrue(text.contains("name=\"signer_public_key\"\r\n\r\n11aa\r\n"))
        XCTAssertTrue(text.contains("name=\"sha256\"\r\n\r\nab12\r\n"))
        XCTAssertTrue(text.contains("name=\"signature\"\r\n\r\ncc34\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"pfp.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("\r\n--fw-test--\r\n"))
        // The JPEG bytes themselves ride in the body, unescaped.
        XCTAssertTrue(body.contains(jpeg))
    }
}
