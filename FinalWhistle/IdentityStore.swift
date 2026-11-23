import CryptoKit
import Foundation
import LocalAuthentication
import os

/// Identity: Hypersnap FIDs and their keys, on this phone.
///
/// A device can hold several FIDs, each controlled by its own custody
/// address. The custody key is the master key and stays in the Keychain,
/// gated by Face ID / Touch ID / device passcode; the signer seed is a
/// session key (30-day sliding window) and is not gated, so posting never
/// prompts. Signing out only deactivates the account: the keys stay, and
/// tapping the account signs back in. There is no delete-custody in the
/// app.
///
/// Two ways to add an account, both in the UI:
///   A. Bring your FID: enter a FID number and the 32-byte Ed25519 signer
///      seed (hex) from a prior onboarding. The seed is stored only in the
///      Keychain. Verification is real: the user is fetched over HTTP and
///      the signer must appear in GetSignersByFid for that FID. If the
///      gRPC check cannot run, the identity is NOT stored and no
///      verification is claimed. A brought FID has no custody key on this
///      phone (signer only), so it cannot make a fresh signer here.
///   B. Create a new native FID: fresh custody key + fresh Ed25519 signer
///      are generated on the device, PoW is mined, NativeOnboard is
///      EIP-712 signed by custody, then a gasless KeyAdd authorises the
///      signer. Keys are saved to the Keychain only after the FID is
///      assigned and the signer is active.
///
/// Custody is immutable in this release and one custody address gets one
/// native FID. Losing the custody key loses the FID. The app shows the
/// custody address; the private key is only shown when the user
/// explicitly asks to back it up, behind a warning, and is never
/// logged or uploaded.
@MainActor
final class IdentityStore: ObservableObject {
    @Published private(set) var identities: [IdentityRecord] = []
    @Published private(set) var record: IdentityRecord?
    @Published private(set) var profile: UserResponse.User?
    @Published private(set) var status: String = ""
    @Published private(set) var isWorking: Bool = false
    @Published private(set) var lastError: String?
    // Authorization: whether the active account's current signer is
    // active on the node, and when it would expire if unused. This is
    // the node's own view (last_used_at + ttl), so it slides with use.
    @Published private(set) var authorizationChecked = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var authorizationExpiresAt: Date?
    @Published private(set) var authorizationError: String?

    private let logger = Logger(subsystem: "app.final-whistle", category: "identity")
    private let libraryStore = LocalStore<IdentityLibrary>(fileName: "identities.json")
    private let legacyRecordStore = LocalStore<IdentityRecord>(fileName: "identity.json")

    var isSignedIn: Bool { record != nil }

    init() {
        migrateLegacyIdentityIfNeeded()
        if let library = try? libraryStore.load() {
            identities = library.identities
            if let active = library.activeFID {
                record = library.identities.first { $0.fid.value == active }
            }
        }
        if record != nil {
            Task { await refreshProfile() }
        }
    }

    // MARK: - Library

    private func saveLibrary() throws {
        let library = IdentityLibrary(version: 1, identities: identities, activeFID: record?.fid.value)
        try libraryStore.save(library)
    }

    /// Insert or replace a record in the list, keeping the active copy in
    /// sync. The list is ordered by creation, oldest first.
    private func upsertIdentity(_ newRecord: IdentityRecord, makeActive: Bool) {
        if let index = identities.firstIndex(where: { $0.fid == newRecord.fid }) {
            identities[index] = newRecord
        } else {
            identities.append(newRecord)
            identities.sort { $0.createdAt < $1.createdAt }
        }
        if makeActive {
            record = newRecord
            profile = nil
        } else if record?.fid == newRecord.fid {
            record = newRecord
        }
    }

    /// One-time migration from the single-account layout (identity.json +
    /// the two legacy Keychain items) to the multi-account library. It
    /// never deletes an old key until the new one is saved, and it only
    /// promotes the library once every key that existed has moved. If
    /// anything fails, the old state stays and the migration retries on
    /// the next launch. Reading the legacy items never prompts: they were
    /// saved without user presence.
    private func migrateLegacyIdentityIfNeeded() {
        if (try? libraryStore.load()) != nil { return }
        guard let old = try? legacyRecordStore.load() else { return }
        let custody = old.custodyAddress
        var keysOK = true
        if let custodyKey = try? KeychainStore.load(account: KeychainStore.legacyCustodyAccount) {
            do {
                try KeychainStore.save(custodyKey, account: KeychainStore.custodyAccount(for: custody), requiresUserPresence: true)
                KeychainStore.delete(account: KeychainStore.legacyCustodyAccount)
            } catch {
                logger.info("custody key migration failed: \(error.localizedDescription)")
                keysOK = false
            }
        }
        if let signerSeed = try? KeychainStore.load(account: KeychainStore.legacySignerAccount) {
            do {
                try KeychainStore.save(signerSeed, account: KeychainStore.signerAccount(for: custody))
                KeychainStore.delete(account: KeychainStore.legacySignerAccount)
            } catch {
                logger.info("signer seed migration failed: \(error.localizedDescription)")
                keysOK = false
            }
        }
        guard keysOK else { return }
        let library = IdentityLibrary(version: 1, identities: [old], activeFID: old.fid.value)
        do {
            try libraryStore.save(library)
            legacyRecordStore.delete()
        } catch {
            logger.info("identity library migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Profile

    func refreshProfile() async {
        guard let fid = record?.fid else { return }
        do {
            let user = try await FeedService.user(fid: fid)
            profile = user
            // Cache the display info on the record so the account list
            // can show it without a fetch.
            if var current = record {
                let newDisplay = user.displayName
                let newPFP = user.pfpURL?.absoluteString
                if current.displayName != newDisplay || current.pfpURL != newPFP {
                    current.displayName = newDisplay
                    current.pfpURL = newPFP
                    upsertIdentity(current, makeActive: false)
                    try? saveLibrary()
                }
            }
        } catch {
            logger.info("profile refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Bring your FID

    /// Bring an existing FID + signer seed. Throws on any verification failure.
    /// The account is added to the list and made active.
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
        // 3. Only now store anything. A brought FID has no custody key on
        // this phone (signer only); the custody address comes from the user.
        let custodyAddress = user.custodyAddress ?? ""
        try KeychainStore.save(seed, account: KeychainStore.signerAccount(for: custodyAddress))
        let newRecord = IdentityRecord(
            fid: FID(fid),
            custodyAddress: custodyAddress,
            signerPublicKeyHex: signer.publicKey.hexString,
            createdAt: Date(),
            signerExpiresAt: nil, // Unknown for a brought identity; the node owns the TTL.
            displayName: user.displayName,
            pfpURL: user.pfpURL?.absoluteString
        )
        upsertIdentity(newRecord, makeActive: true)
        try saveLibrary()
        self.profile = user
        status = ""
        // The signer was just verified active on the node, so the
        // Authorization row shows Authorized at once.
        markAuthorized(expiresAt: nil)
    }

    // MARK: - Bring your FID with the custody (recovery) key

    /// Bring an existing FID with its custody private key — the recovery
    /// key the user backed up. The custody key proves ownership of the
    /// account; a fresh signer is made for this phone with a KeyAdd, so
    /// the user does not need a live signer seed (the old one may have
    /// expired after 30 days without use, or the user may never have
    /// saved it). Throws on any verification failure. The account is
    /// added to the list and made active, with its custody key stored on
    /// this phone so it can renew its signer again later.
    func bringYourFIDWithCustody(fid: UInt64, custodyPrivateKeyHex: String) async throws {
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        status = "Checking the recovery key…"
        let hex = custodyPrivateKeyHex.trimmingCharacters(in: .whitespaces)
        guard let custodyKey = Data(hex: hex), custodyKey.count == 32 else {
            throw IdentityError.badCustodyKey
        }
        let custodyAddress = try CustodyKeys.address(privateKey: custodyKey)
        // 1. The user must exist over HTTP, and the custody key must
        // belong to this FID. A mismatch means the wrong account ID or
        // the wrong key — say so plainly instead of the node error.
        let user = try await FeedService.user(fid: FID(fid))
        guard user.fid.value == fid else { throw IdentityError.fidMismatch }
        let nodeCustody = (user.custodyAddress ?? "")
            .lowercased()
            .replacingOccurrences(of: "0x", with: "", options: .anchored)
        let derivedCustody = custodyAddress
            .lowercased()
            .replacingOccurrences(of: "0x", with: "", options: .anchored)
        guard nodeCustody == derivedCustody else { throw IdentityError.custodyMismatch }
        // 2. Make a fresh signer for this phone (KeyAdd at the next
        // nonce) and store it. The custody key is stored too, gated by
        // Face ID / passcode, so the account can renew again later.
        status = "Making a fresh sign-in key…"
        let renewed = try await renewSigner(fid: fid, custodyAddress: custodyAddress, custodyKey: custodyKey)
        try KeychainStore.save(custodyKey, account: KeychainStore.custodyAccount(for: custodyAddress), requiresUserPresence: true)
        let newRecord = IdentityRecord(
            fid: FID(fid),
            custodyAddress: custodyAddress,
            signerPublicKeyHex: renewed.publicKeyHex,
            createdAt: Date(),
            signerExpiresAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            displayName: user.displayName,
            pfpURL: user.pfpURL?.absoluteString
        )
        upsertIdentity(newRecord, makeActive: true)
        try saveLibrary()
        self.profile = user
        status = ""
        // A fresh signer was just made with a KeyAdd, so the
        // Authorization row shows Authorized at once.
        markAuthorized(expiresAt: newRecord.signerExpiresAt)
    }

    // MARK: - Create a new native FID

    /// Full native onboarding. Progress is reported in `status` so the UI
    /// can show which step is running. Throws on the first failing step.
    /// The new FID is added to the list and made active.
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

        // Gasless KeyAdd for the fresh signer (nonce 1: first signer on a
        // fresh custody).
        status = "Authorising the signer…"
        try await addSigner(
            fid: assignedFID, custodyPrivateKey: custodyPrivateKey,
            custodyAddress: custodyAddress, signerPublicKey: signerPublicKey, signer: signer
        )

        // Only now persist anything. The custody key is gated by user
        // presence; the signer seed is a session key and is not gated.
        try KeychainStore.save(custodyPrivateKey, account: KeychainStore.custodyAccount(for: custodyAddress), requiresUserPresence: true)
        try KeychainStore.save(signerSeed, account: KeychainStore.signerAccount(for: custodyAddress))
        let newRecord = IdentityRecord(
            fid: FID(assignedFID),
            custodyAddress: custodyAddress,
            signerPublicKeyHex: signerPublicKey.hexString,
            createdAt: Date(),
            signerExpiresAt: Date().addingTimeInterval(30 * 24 * 3600)
        )
        upsertIdentity(newRecord, makeActive: true)
        try saveLibrary()
        status = ""
        // A fresh signer was just made with a KeyAdd, so the
        // Authorization row shows Authorized at once.
        markAuthorized(expiresAt: newRecord.signerExpiresAt)
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
    /// custody; a renewal passes the next nonce from the node
    /// (current_user_nonce + 1), since the node rejects a nonce that is
    /// not strictly greater than the FID's current value.
    private func addSigner(
        fid: UInt64, custodyPrivateKey: Data, custodyAddress: String,
        signerPublicKey: Data, signer: Ed25519Signer, nonce: UInt32 = 1
    ) async throws {
        let deadline = Date().farcasterEpoch + 86_400
        let ttl: UInt32 = 30 * 86_400
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

    // MARK: - Switching accounts

    /// Ask for Face ID / Touch ID / device passcode. Used for signer-only
    /// accounts, which have no custody key to gate the switch on.
    private func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw IdentityError.authenticationUnavailable
        }
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch let error as LAError where error.code == .userCancel {
            throw IdentityError.authenticationCancelled
        } catch {
            throw IdentityError.authenticationFailed
        }
    }

    /// Make a fresh signer for an account from its custody key (a new
    /// KeyAdd with the next user nonce). Used when the stored signer has
    /// expired after 30 days without use. Returns the new signer seed and
    /// public key hex.
    /// The nonce for a new KeyAdd. Hypersnap uses two nonce schemes
    /// for offchain signers, and the wrong one is a stale replay.
    /// Native FIDs get small sequential nonces (1, 2, 3...), so the
    /// next one is current + 1. Classic FIDs get timestamp nonces
    /// (the Unix time of the KeyAdd, e.g. 1795334148), so current + 1
    /// is a second in the past by the time the KeyAdd is submitted
    /// and the hub rejects it as stale. A timestamp nonce is any
    /// value that looks like a Unix time; for those, the next nonce
    /// is the later of current + 1 and now, so it is always ahead of
    /// the last one and never in the past.
    private static func nextKeyAddNonce(currentUserNonce: UInt32) -> UInt32 {
        if currentUserNonce > 1_000_000 {
            let now = UInt32(Date().timeIntervalSince1970)
            return max(currentUserNonce + 1, now)
        }
        return currentUserNonce + 1
    }

    private func renewSigner(fid: UInt64, custodyAddress: String, custodyKey: Data) async throws -> (seed: Data, publicKeyHex: String) {
        // `guard let _ =` pins the failable Data.init?(hex:) — a bare
        // Data(hex:) is ambiguous with a non-failable hex init in the
        // module (CryptoSwift), and the compiler cannot pick one.
        guard let _ = Data(hex: custodyAddress) else { throw IdentityError.badCustody }
        let signer = Ed25519Signer()
        let info = try await HypersnapClient.signersByFID(fid)
        try await addSigner(
            fid: fid, custodyPrivateKey: custodyKey,
            custodyAddress: custodyAddress, signerPublicKey: signer.publicKey, signer: signer,
            nonce: Self.nextKeyAddNonce(currentUserNonce: info.currentUserNonce)
        )
        try KeychainStore.save(signer.seed, account: KeychainStore.signerAccount(for: custodyAddress))
        return (signer.seed, signer.publicKey.hexString)
    }

    /// Switch to another saved account. Face ID / passcode gates the
    /// switch: for an account with a custody key on this phone, reading
    /// the key is what prompts; for a signer-only account, the app asks
    /// explicitly. If the stored signer has gone quiet for 30 days and
    /// expired, a fresh signer is made from the custody key. Throws if
    /// the user cancels the unlock or the signer cannot be renewed.
    func switchTo(fid: UInt64) async throws {
        guard let target = identities.first(where: { $0.fid.value == fid }) else {
            throw IdentityError.notSignedIn
        }
        guard target.fid.value != record?.fid.value else { return }
        status = "Unlocking this account…"
        // 1. Authenticate. Reading the custody key prompts for Face ID /
        // passcode (it is gated by user presence). A signer-only account
        // has no custody key here, so the app asks explicitly instead.
        var custodyKey: Data?
        do {
            custodyKey = try KeychainStore.load(
                account: KeychainStore.custodyAccount(for: target.custodyAddress),
                prompt: "Unlock to switch accounts"
            )
        } catch KeychainStore.KeychainError.notFound {
            custodyKey = nil
            try await authenticate(reason: "Unlock to switch accounts")
        }
        // 2. Is the stored signer still active?
        status = "Checking the signer…"
        var signerPublicKeyHex = target.signerPublicKeyHex
        var signerOK = false
        if let seed = try? KeychainStore.load(account: KeychainStore.signerAccount(for: target.custodyAddress)),
           let publicKey = Data(hex: signerPublicKeyHex),
           (try? await HypersnapClient.signerIsActive(fid: fid, signerPublicKey: publicKey)) == true {
            _ = seed
            signerOK = true
        }
        // 3. If the signer is gone (30 days without use), make a fresh one
        // from the custody key.
        if !signerOK {
            guard let custodyKey else {
                throw IdentityError.signerNotActive
            }
            status = "Making a fresh signer…"
            let renewed = try await renewSigner(fid: fid, custodyAddress: target.custodyAddress, custodyKey: custodyKey)
            signerPublicKeyHex = renewed.publicKeyHex
        }
        // 4. Activate. The keys stay in the Keychain; only the active
        // pointer moves. The feed reloads for the new FID on its own
        // (FeedView watches identity.record).
        var updated = target
        updated.signerPublicKeyHex = signerPublicKeyHex
        updated.signerExpiresAt = Date().addingTimeInterval(30 * 24 * 3600)
        upsertIdentity(updated, makeActive: true)
        try saveLibrary()
        status = ""
        // The signer was just verified active, or a fresh one was just
        // made, so the Authorization row shows Authorized at once.
        markAuthorized(expiresAt: updated.signerExpiresAt)
        await refreshProfile()
    }

    // MARK: - Sign out

    /// Sign out of the active account. This only deactivates it: the
    /// custody key and the signer seed stay in this phone's Keychain, and
    /// the account stays in the list, so tapping it signs back in (Face
    /// ID). There is no way to delete a custody key from this app.
    func signOut() {
        record = nil
        profile = nil
        status = ""
        lastError = nil
        authorizationChecked = false
        isAuthorized = false
        authorizationExpiresAt = nil
        authorizationError = nil
        try? saveLibrary()
    }

    // MARK: - Authorizing Final Whistle

    /// After a sign-in, a switch, or a renewal, the signer is known
    /// active — it was just verified on the node or just created with
    /// a KeyAdd — so the Authorization row can show Authorized at
    /// once instead of waiting for the next appear-triggered node
    /// read. The node read still runs on the next appear to confirm.
    private func markAuthorized(expiresAt: Date?) {
        authorizationChecked = true
        isAuthorized = true
        authorizationExpiresAt = expiresAt
        authorizationError = nil
    }

    /// Check the active account's authorization on the node: whether its
    /// current signer is active, and when it would expire if unused.
    /// This is the node's own view, so it slides with use. Safe to call
    /// any time; a failure leaves the last known state and records the
    /// error for the panel to show.
    func refreshAuthorization() async {
        guard let record else {
            authorizationChecked = true
            isAuthorized = false
            authorizationExpiresAt = nil
            authorizationError = nil
            return
        }
        do {
            let info = try await HypersnapClient.signersByFID(record.fid.value)
            // Explicit Data? pins the failable Data.init?(hex:) — a bare
            // Data(hex:) is ambiguous with a non-failable hex init in
            // the module (CryptoSwift), and the compiler cannot pick one.
            let publicKey: Data? = Data(hex: record.signerPublicKeyHex)
            let match = info.signers.first { $0.publicKey == publicKey }
            isAuthorized = match != nil
            authorizationExpiresAt = match?.expiresAt
            authorizationError = nil
        } catch {
            authorizationError = error.localizedDescription
            isAuthorized = false
            authorizationExpiresAt = nil
        }
        authorizationChecked = true
    }

    /// Authorize Final Whistle to act as the active account: make a fresh
    /// signer and register it with a KeyAdd (the next user nonce). This
    /// is the renewal the user thinks of as "authorizing the app" — the
    /// app can then post, reply, like, and recast as the account, for a
    /// 30-day window that renews with use. It needs the custody key, so
    /// it asks for Face ID / passcode. A signer-only account (brought
    /// FID, no custody key) cannot be authorized here.
    func authorizeApp() async throws {
        guard let record else { throw IdentityError.notSignedIn }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        status = "Unlocking to authorize Final Whistle…"
        let custodyKey: Data
        do {
            custodyKey = try KeychainStore.load(
                account: KeychainStore.custodyAccount(for: record.custodyAddress),
                prompt: "Unlock to authorize Final Whistle"
            )
        } catch KeychainStore.KeychainError.notFound {
            throw IdentityError.noCustodyKey
        }
        status = "Authorizing Final Whistle…"
        let renewed = try await renewSigner(fid: record.fid.value, custodyAddress: record.custodyAddress, custodyKey: custodyKey)
        var updated = record
        updated.signerPublicKeyHex = renewed.publicKeyHex
        updated.signerExpiresAt = Date().addingTimeInterval(30 * 24 * 3600)
        upsertIdentity(updated, makeActive: false)
        try saveLibrary()
        status = ""
        await refreshAuthorization()
    }

    // MARK: - Posting and reactions (identity required)

    private func signerSeed() throws -> Data {
        guard let record else { throw IdentityError.notSignedIn }
        return try KeychainStore.load(account: KeychainStore.signerAccount(for: record.custodyAddress))
    }

    /// The custody private key as 0x-prefixed hex, for backup. This is
    /// the key that controls the FID: custody is immutable and one
    /// custody address gets one native FID, so losing it loses the FID.
    /// Reading it prompts for Face ID / passcode. The caller is
    /// responsible for the warning and for never logging the value.
    /// Throws KeychainError.notFound when this phone holds a signer only
    /// (a brought-your-own FID), because the custody key was never stored
    /// here.
    func custodyPrivateKeyHex() throws -> String {
        guard let record else { throw IdentityError.notSignedIn }
        let key = try KeychainStore.load(
            account: KeychainStore.custodyAccount(for: record.custodyAddress),
            prompt: "Unlock to show the recovery key"
        )
        guard key.count == 32 else { throw IdentityError.badCustody }
        return "0x" + key.hexString
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
    func post(text: String, parentURL: String, linkURLs: [String] = []) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: nil, parentHash: nil,
            parentURL: parentURL,
            linkURLs: linkURLs
        )
        let hash = try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
        return hash
    }

    /// Post a new top-level cast into the /football channel.
    func post(text: String, linkURLs: [String] = []) async throws -> String {
        try await post(text: text, parentURL: FarcasterMessages.footballChannelURL, linkURLs: linkURLs)
    }

    /// Quote-repost a cast: a new top-level cast into /football carrying
    /// the quoted cast as an embed (Quilcast's post() with quote).
    /// This is the app's only repost: there is no plain recast button.
    func quote(cast: Cast, text: String, linkURLs: [String] = []) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let quotedHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: nil, parentHash: nil,
            parentURL: FarcasterMessages.footballChannelURL,
            quotedCasts: [(fid: cast.author.fid.value, hash: quotedHash)],
            linkURLs: linkURLs
        )
        return try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
    }

    /// Reply to a cast with a sticker: a cast with no text and the
    /// sticker image as its only embed, parented to the cast (not a
    /// parent URL). Any client shows it as a picture; this app draws
    /// it bare (see StickerView).
    /// Send a sticker as a reply: the sticker's shortcode
    /// (`:packid:emojiconid:`) as the text plus the image as an
    /// ordinary embed. Client-side inline emoji, no protocol change:
    /// a reader that knows the pack renders the image inline (or
    /// large, when the text is only the shortcode); a reader that
    /// does not just shows the shortcode text plus the picture.
    /// The text defaults to "" for a bare sticker with no shortcode.
    func replySticker(to cast: Cast, url: String, text: String = "") async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let parentHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: text, mentions: [], mentionPositions: [],
            parentAuthorFID: cast.author.fid.value, parentHash: parentHash,
            imageURLs: [url]
        )
        return try await HypersnapClient.submitSigned(data: data, fid: fid.value, signerSeed: seed)
    }

    /// Reply to a cast. parent_cast_id.fid is the PARENT author's FID.
    func reply(to cast: Cast, text: String, linkURLs: [String] = []) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        guard let parentHash = Data(hex: cast.hash) else { throw IdentityError.badHash }
        let seed = try signerSeed()
        let (stored, fids, positions) = await resolveMentions(in: text)
        let data = FarcasterMessages.castAddData(
            fid: fid.value, timestamp: Date().farcasterEpoch,
            text: stored, mentions: fids, mentionPositions: positions,
            parentAuthorFID: cast.author.fid.value, parentHash: parentHash,
            linkURLs: linkURLs
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

    /// Set the display name (UserDataAdd type 2, free-form, max 32
    /// characters). This is not the username — the username is the
    /// registered fname, which native FIDs do not have. The cached
    /// display name on the record is updated right away so the account
    /// list shows it without waiting for the profile refresh.
    func setDisplayName(_ name: String) async throws -> String {
        let hash = try await setUserData(type: 2, value: name)
        if var current = record {
            current.displayName = name
            upsertIdentity(current, makeActive: false)
            try? saveLibrary()
        }
        return hash
    }

    /// Upload a prepared JPEG as this FID's profile picture: hash it,
    /// sign the binding message with the FID's Ed25519 signer key, and
    /// upload it to Castrater. Returns the public URL, stable per FID.
    /// The caller saves that URL with setPFP. See
    /// docs/pfp-upload-api.md for the endpoint contract.
    func uploadPFP(jpeg: Data) async throws -> String {
        guard let fid = record?.fid else { throw IdentityError.notSignedIn }
        let seed = try signerSeed()
        let sha256Hex = Data(SHA256.hash(data: jpeg)).hexString
        let signer = try Ed25519Signer(seed: seed)
        let signature = try signer.sign(
            ProfilePhotoService.signatureMessage(fid: fid.value, sha256Hex: sha256Hex)
        )
        return try await ProfilePhotoService.uploadPFP(
            jpeg: jpeg, fid: fid.value,
            signerPublicKeyHex: signer.publicKey.hexString,
            sha256Hex: sha256Hex, signatureHex: signature.hexString
        )
    }

    enum IdentityError: Error, LocalizedError {
        case badSeed
        case badCustody
        case badCustodyKey
        case custodyMismatch
        case badHash
        case fidMismatch
        case signerNotActive
        case registrationInactive
        case anchorExpired
        case noFIDAssigned
        case notSignedIn
        case noCustodyKey
        case authenticationUnavailable
        case authenticationCancelled
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .badSeed: return "The signer seed must be 64 hex characters (32 bytes)."
            case .badCustody: return "The custody address is not valid."
            case .badCustodyKey: return "The recovery key must be 64 hex characters (32 bytes)."
            case .custodyMismatch: return "That recovery key does not belong to this account ID. Check the account ID and the key."
            case .badHash: return "The cast hash is not valid hex."
            case .fidMismatch: return "The user fetched for that FID does not match."
            case .signerNotActive: return "That signer is not active for this FID on the node."
            case .registrationInactive: return "Native registration is not active on this node right now."
            case .anchorExpired: return "The registration anchor expired while mining. Try again."
            case .noFIDAssigned: return "No FID was assigned within 60 seconds."
            case .notSignedIn: return "Sign in first."
            case .noCustodyKey: return "This account has no custody key on this phone, so Final Whistle cannot authorize a new signer for it."
            case .authenticationUnavailable: return "This phone cannot ask for Face ID or a passcode right now."
            case .authenticationCancelled: return "Unlock was cancelled."
            case .authenticationFailed: return "Unlock failed. Try again."
            }
        }
    }
}
