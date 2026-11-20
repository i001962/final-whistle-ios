import Foundation
import os

/// Identity: a Hypersnap native FID plus its keys.
///
/// Two flows, both in the UI:
///   A. Bring your FID: enter a FID number and the 32-byte Ed25519 signer
///      seed (hex) from a prior onboarding. The seed is stored only in the
///      Keychain. Verification is real: the user is fetched over HTTP and
///      the signer must appear in GetSignersByFid for that FID. If the
///      gRPC check cannot run, the identity is NOT stored and no
///      verification is claimed.
///   B. Create a new native FID: fresh custody key + fresh Ed25519 signer
///      are generated on the device, PoW is mined, NativeOnboard is
///      EIP-712 signed by custody, then a gasless KeyAdd authorises the
///      signer. Keys are saved to the Keychain only after the FID is
///      assigned and the signer is active.
///
/// Custody is immutable in this release and one custody address gets one
/// native FID. Losing the custody key loses the FID. The app shows the
/// custody address and never shows the private key or the seed.
@MainActor
final class IdentityStore: ObservableObject {
    @Published private(set) var record: IdentityRecord?
    @Published private(set) var profile: UserResponse.User?
    @Published private(set) var status: String = ""
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?

    private let logger = Logger(subsystem: "app.final-whistle", category: "identity")
    private let recordStore = LocalStore<IdentityRecord>(fileName: "identity.json")

    var isSignedIn: Bool { record != nil }

    init() {
        if let saved = try? recordStore.load() {
            record = saved
            Task { await refreshProfile() }
        }
    }

    // MARK: - Profile

    func refreshProfile() async {
        guard let fid = record?.fid else { return }
        do {
            profile = try await FeedService.user(fid: fid)
        } catch {
            logger.info("profile refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Bring your FID

    /// Bring an existing FID + signer seed. Throws on any verification failure.
    func bringYourFID(fid: UInt64, signerSeedHex: String) async throws {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        status = "Checking the FID…"
        guard let seed = Data(hex: signerSeedHex), seed.count == 32 else {
            throw IdentityError.badSeed
        }
        let signer = try Ed25519Signer(seed: seed)
        // 1. The user must exist over HTTP.
        let user = try await FeedService.user(fid: FID(fid))
        guard user.fid.value == fid else { throw IdentityError.fidMismatch }
        // 2. The signer must be active for this FID on the node. This is a
        // real check, not a claim: if it cannot run, we stop here.
        status = "Checking the signer on the node…"
        let active = try await HypersnapClient.signerIsActive(fid: fid, signerPublicKey: signer.publicKey)
        guard active else { throw IdentityError.signerNotActive }
        // 3. Only now store anything.
        try KeychainStore.save(seed, account: KeychainStore.signerAccount)
        let record = IdentityRecord(
            fid: FID(fid),
            custodyAddress: user.custodyAddress ?? "",
            signerPublicKeyHex: signer.publicKey.hexString,
            createdAt: Date(),
            signerExpiresAt: nil // Unknown for a brought identity; the node owns the TTL.
        )
        try recordStore.save(record)
        self.record = record
        self.profile = user
        status = ""
    }

    // MARK: - Create a new native FID

    /// Full native onboarding. Progress is reported in `status` so the UI
    /// can show which step is running. Throws on the first failing step.
    func createNewFID() async throws {
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        // Fresh keys, generated on the device. Never reuse a real wallet key.
        status = "Generating a fresh custody key and signer…"
        let custodyPrivateKey = try CustodyKeys.generatePrivateKey()
        let custodyAddress = try CustodyKeys.address(privateKey: custodyPrivateKey)
        guard let custodyBytes = Data(hex: custodyAddress) else { throw IdentityError.badCustody }
        let signer = Ed25519Signer()
        let signerSeed = signer.seed
        let signerPublicKey = signer.publicKey

        // Resume: this custody may already have a FID.
        status = "Checking whether this custody already has a FID…"
        var fid = try await HypersnapClient.fidForCustody(custodyBytes)

        if fid == nil {
            // Registration info and PoW. The PoW, the struct hash, and the
            // body all use the ORIGINAL anchor; the re-fetch only checks
            // that the anchor is still inside its window.
            status = "Fetching registration info…"
            let info = try await HypersnapClient.registrationInfo()
            guard info.active else { throw IdentityError.registrationInactive }
            let anchorHeight = info.anchorHeight
            let anchorHash = info.anchorHash
            let difficultyBits = info.minDifficultyBits
            status = "Mining proof of work…"
            let nonce = try await Task.detached(priority: .userInitiated) {
                try FarcasterMessages.minePoW(custody: custodyBytes, anchor: anchorHash, bits: difficultyBits)
            }.value
            // Re-fetch: abort if the anchor left its window.
            let latest = try await HypersnapClient.registrationInfo()
            guard latest.nextBlock >= anchorHeight,
                  latest.nextBlock - anchorHeight <= info.anchorWindow else {
                throw IdentityError.anchorExpired
            }
            let commitment = FarcasterMessages.gateCommitment(nonce: nonce, difficultyBits: difficultyBits)
            let structHash = Ethereum.hyperNativeOnboardStructHash(
                custody: custodyAddress, anchorHeight: anchorHeight,
                anchorHash: anchorHash, gateCommitment: commitment
            )
            status = "Signing the onboarding message…"
            let custodySignature = try CustodyKeys.signEIP712(
                domainName: "HypersnapNativeOnboard", domainVersion: "1", chainId: 10,
                structHash: structHash, privateKey: custodyPrivateKey
            )
            let data = FarcasterMessages.nativeOnboardData(
                timestamp: Date().farcasterEpoch, custody: custodyBytes,
                custodySignature: custodySignature, anchorHeight: anchorHeight,
                anchorHash: anchorHash, nonce: nonce, difficultyBits: difficultyBits
            )
            // NativeOnboard carries no outer signature.
            let message = FarcasterMessages.message(
                data: data, signerPublicKey: Data(), signature: Data(), signatureScheme: 0
            )
            status = "Submitting onboarding…"
            _ = try await HypersnapClient.submitMessage(message)
            status = "Waiting for the FID to be assigned…"
            fid = try await pollFID(custody: custodyBytes)
        }

        guard let assignedFID = fid else { throw IdentityError.noFIDAssigned }

        // Gasless KeyAdd for the fresh signer.
        status = "Authorising the signer…"
        try await addSigner(
            fid: assignedFID, custodyPrivateKey: custodyPrivateKey,
            custodyAddress: custodyAddress, signerPublicKey: signerPublicKey, signer: signer
        )

        // Only now persist anything.
        try KeychainStore.save(custodyPrivateKey, account: KeychainStore.custodyAccount)
        try KeychainStore.save(signerSeed, account: KeychainStore.signerAccount)
        let record = IdentityRecord(
            fid: FID(assignedFID),
            custodyAddress: custodyAddress,
            signerPublicKeyHex: signerPublicKey.hexString,
            createdAt: Date(),
            signerExpiresAt: Date().addingTimeInterval(30 * 24 * 3600)
        )
        try recordStore.save(record)
        self.record = record
        status = ""
        await refreshProfile()
    }

    private func pollFID(custody: Data) async throws -> UInt64? {
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if let fid = try await HypersnapClient.fidForCustody(custody) { return fid }
        }
        return nil
    }

    private func pollSigner(fid: UInt64, signerPublicKey: Data) async throws -> Bool {
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if try await HypersnapClient.signerIsActive(fid: fid, signerPublicKey: signerPublicKey) {
                return true
            }
        }
        return false
    }

    /// Gasless KeyAdd. Nonce 1 is correct for a first signer on a fresh
    /// custody; if this custody already authorised a signer, the node will
    /// reject it and the error is surfaced, not guessed around.
    private func addSigner(
        fid: UInt64, custodyPrivateKey: Data, custodyAddress: String,
        signerPublicKey: Data, signer: Ed25519Signer
    ) async throws {
        let deadline = Date().farcasterEpoch + 86_400
        let ttl: UInt32 = 30 * 86_400
        let nonce: UInt32 = 1
        let scopes: [UInt32] = [1, 2, 3, 4, 5, 6, 11, 12]
        let keyAddHash = Ethereum.keyAddStructHash(
            fid: fid, key: signerPublicKey, keyType: 1, scopes: scopes,
            ttl: ttl, nonce: nonce, deadline: UInt64(deadline)
        )
        let keyAddSignature = try CustodyKeys.signEIP712(
            domainName: "Farcaster KeyAdd", domainVersion: "1", chainId: 1,
            structHash: keyAddHash, privateKey: custodyPrivateKey
        )
        let skrHash = Ethereum.signedKeyRequestStructHash(
            requestFid: fid, key: signerPublicKey, deadline: UInt64(deadline)
        )
        let skrSignature = try CustodyKeys.signEIP712(
            domainName: "Farcaster KeyAdd", domainVersion: "1", chainId: 1,
            structHash: skrHash, privateKey: custodyPrivateKey
        )
        let metadata = FarcasterMessages.signedKeyRequestMetadata(
            requestFid: fid, requestSigner: custodyAddress,
            signature: skrSignature, deadline: UInt64(deadline)
        )
        let data = FarcasterMessages.keyAddData(
            fid: fid, timestamp: Date().farcasterEpoch, signerPublicKey: signerPublicKey,
            custodySignature: keyAddSignature, deadline: deadline, nonce: nonce,
            metadata: metadata, scopes: scopes, ttl: ttl
        )
        _ = try await HypersnapClient.submitSigned(data: data, fid: fid, signerSeed: signer.seed)
        guard try await pollSigner(fid: fid, signerPublicKey: signerPublicKey) else {
            throw IdentityError.signerNotActive
        }
    }

    // MARK: - Sign out

    func signOut() {
        KeychainStore.deleteAllIdentityKeys()
        recordStore.delete()
        record = nil
        profile = nil
        status = ""
        lastError = nil
    }

    // MARK: - Posting and reactions (identity required)

    private func signerSeed() throws -> Data {
        guard record != nil else { throw IdentityError.notSignedIn }
        return try KeychainStore.load(account: KeychainStore.signerAccount)
    }

    /// Resolve @username tokens in display text to FIDs, then build the
    /// stored text with the tokens removed, per the mention encoding.
    private func resolveMentions(in text: String) async -> (stored: String, fids: [UInt64], positions: [UInt32]) {
        let tokens = FarcasterMessages.mentionTokens(in: text)
        var pairs: [(username: String, fid: UInt64)] = []
        for token in tokens {
            if let fid = try? await FeedService.fid(forUsername: token) {
                pairs.append((token, fid.value))
            }
        }
        return FarcasterMessages.encodeMentions(displayText: text, mentions: pairs)
    }

    /// Post a new top-level cast under a parent URL. Returns the cast
    /// hash (0x...). The parent_url is what puts the cast in a feed:
    /// without it the cast goes to the global feed and never shows in
    /// the app's feed or a match room.
    func post(text: String, parentURL: String) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: nil, parentHash: nil,
            parentURL: parentURL
        )
        let hash = try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
        return hash
    }

    /// Post a new top-level cast into the /football channel.
    func post(text: String) async throws -> String {
        try await post(text: text, parentURL: FarcasterMessages.footballChannelURL)
    }

    /// Quote-repost a cast: a new top-level cast into /football carrying
    /// the quoted cast as an embed (Quilcast's post() with quote).
    /// This is the app's only repost: there is no plain recast button.
    func quote(cast: Cast, text: String) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let quotedHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: nil, parentHash: nil,
            parentURL: FarcasterMessages.footballChannelURL,
            quotedCasts: [(fid: cast.author.fid.value, hash: quotedHash)]
        )
        return try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
    }

    /// Reply to a cast. parent_cast_id.fid is the PARENT author's FID.
    func reply(to cast: Cast, text: String) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let parentHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: cast.author.fid.value, parentHash: parentHash
        )
        return try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
    }

    /// Like (type 1) or recast (type 2). Returns the reaction message hash.
    func react(to cast: Cast, type: UInt64, remove: Bool = false) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let targetHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let data = FarcasterMessages.reactionData(
            fid: fid.value, timestamp: Date().farcasterEpoch, reactionType: type,
            targetAuthorFID: cast.author.fid.value, targetHash: targetHash, remove: remove
        )
        return try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
    }

    /// Set a profile field: a UserDataAdd (type 11) with the field's
    /// type (1 pfp, 2 display name, 3 bio, 5 website) and its value.
    /// The pfp value is a public image URL, not an upload — the image
    /// is hosted first (ProfilePhotoService), then its URL goes here.
    /// Returns the message hash. The node takes a moment to index the
    /// new user data, so the profile is refreshed on a short delay;
    /// until then the panel may still show the old value.
    func setUserData(type: UInt64, value: String) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        let seed = try signerSeed()
        let data = FarcasterMessages.userDataAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch, type: type, value: value
        )
        let hash = try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshProfile()
        }
        return hash
    }

    /// Set the profile picture to a public image URL.
    func setPFP(url: String) async throws -> String {
        try await setUserData(type: 1, value: url)
    }

    enum IdentityError: Error, LocalizedError {
        case badSeed
        case badCustody
        case badHash
        case fidMismatch
        case signerNotActive
        case registrationInactive
        case anchorExpired
        case noFIDAssigned
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .badSeed: return "The signer seed must be 64 hex characters (32 bytes)."
            case .badCustody: return "The custody address is not valid."
            case .badHash: return "The cast hash is not valid hex."
            case .fidMismatch: return "The user fetched for that FID does not match."
            case .signerNotActive: return "That signer is not active for this FID on the node."
            case .registrationInactive: return "Native registration is not active on this node right now."
            case .anchorExpired: return "The registration anchor expired while mining. Try again."
            case .noFIDAssigned: return "No FID was assigned within 60 seconds."
            case .notSignedIn: return "Sign in first."
            }
        }
    }
}
