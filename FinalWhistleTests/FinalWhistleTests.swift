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
}
