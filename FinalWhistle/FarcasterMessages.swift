import Foundation
import CryptoKit

/// Farcaster message construction. Field numbers are from Protos/message.proto
/// (farcasterorg/hypersnap). Message types: CastAdd 1, ReactionAdd 3,
/// ReactionRemove 4, UserDataAdd 11, KeyAdd 16, NativeOnboard 160.
/// Hash scheme BLAKE3 (1), signature scheme Ed25519 (1), none (0).
///
/// Parent fix: hs.py do_cast() sets parent_cast_id.fid to the caller's own
/// FID. That is wrong for replies to other authors. parent_cast_id.fid must
/// be the PARENT author's FID, with the parent cast hash. This code does that.
enum FarcasterMessages {
    static let networkMainnet: UInt64 = 1

    /// The channel the app's feed shows. A top-level cast only lands in
    /// /football when CastAddBody carries this as parent_url (field 7).
    /// Without it the cast goes to the global feed and never appears in
    /// the app's feed. Replies carry parent_cast_id instead, never both.
    static let footballChannelURL = "https://farcaster.xyz/~/channel/football"

    // MARK: - MessageData envelope

    /// Build MessageData bytes. bodyField is the protobuf field number of the
    /// body inside MessageData (5 CastAdd, 7 Reaction, 12 UserData,
    /// 19 KeyAdd, 1160 NativeOnboard).
    static func messageData(
        type: UInt64, fid: UInt64, timestamp: UInt32, bodyField: Int, body: Data
    ) -> Data {
        var out = Data()
        out.append(Protobuf.varintField(1, type))
        // Proto3 omits default-valued fields: fid 0 (NativeOnboard) is
        // not written, matching the Python protobuf reference exactly.
        if fid != 0 { out.append(Protobuf.varintField(2, fid)) }
        out.append(Protobuf.varintField(3, UInt64(timestamp)))
        out.append(Protobuf.varintField(4, networkMainnet))
        out.append(Protobuf.bytesField(bodyField, body))
        return out
    }

    /// Full Message bytes: data, data_bytes, hash (BLAKE3-20), hash_scheme,
    /// signature, signature_scheme, signer.
    /// Message fields: data 1, hash 2, hash_scheme 3, signature 4,
    /// signature_scheme 5, signer 6, data_bytes 7.
    static func message(
        data: Data, signerPublicKey: Data, signature: Data, signatureScheme: UInt64
    ) -> Data {
        let hash = Blake3.hash20(data)
        var out = Data()
        out.append(Protobuf.bytesField(1, data))
        out.append(Protobuf.bytesField(2, hash))
        out.append(Protobuf.varintField(3, 1)) // HASH_SCHEME_BLAKE3
        // Proto3 omits empty bytes and zero enums: a NativeOnboard message
        // carries no outer signature, no scheme, and no signer.
        if !signature.isEmpty { out.append(Protobuf.bytesField(4, signature)) }
        if signatureScheme != 0 { out.append(Protobuf.varintField(5, signatureScheme)) }
        if !signerPublicKey.isEmpty { out.append(Protobuf.bytesField(6, signerPublicKey)) }
        out.append(Protobuf.bytesField(7, data))
        return out
    }

    static func messageHash(of data: Data) -> Data {
        Blake3.hash20(data)
    }

    // MARK: - Mentions

    /// Mention encoding, per hs.py encode_mentions(): the literal "@username"
    /// token is REMOVED from the stored text and replaced by nothing at that
    /// byte position; the client renders the username there. A single space
    /// is left in its place in the reference implementation's display form,
    /// but the stored text is the display text with the token deleted.
    /// This function takes display text and (username, fid) pairs and
    /// returns (storedText, fids, bytePositions). Mentions are resolved by
    /// the caller via FeedService.fid(forUsername:).
    static func encodeMentions(
        displayText: String, mentions: [(username: String, fid: UInt64)]
    ) -> (stored: String, fids: [UInt64], positions: [UInt32]) {
        var stored = displayText
        var fids: [UInt64] = []
        var positions: [UInt32] = []
        for (username, fid) in mentions {
            let token = "@" + username
            guard let range = stored.range(of: token) else { continue }
            let bytePosition = UInt32(stored[stored.startIndex..<range.lowerBound].utf8.count)
            stored.replaceSubrange(range, with: "")
            fids.append(fid)
            positions.append(bytePosition)
        }
        return (stored, fids, positions)
    }

    /// Find @username tokens in display text.
    static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        let pattern = "@([A-Za-z0-9_.-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return tokens }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let tokenRange = Range(match.range(at: 1), in: text) {
                tokens.append(String(text[tokenRange]))
            }
        }
        return tokens
    }

    // MARK: - CastAdd (type 1)

    /// CastAddBody fields: mentions 2 (packed uint64), parent_cast_id 3,
    /// text 4, mentions_positions 5 (packed uint32), parent_url 7,
    /// type 8, format_version 9. CastId fields: fid 1, hash 2.
    /// parent_url and parent_cast_id are mutually exclusive: a top-level
    /// cast into a channel sets parent_url, a reply sets parent_cast_id.
    static func castAddBody(
        text: String, mentions: [UInt64], mentionPositions: [UInt32],
        parentAuthorFID: UInt64?, parentHash: Data?, parentURL: String? = nil
    ) -> Data {
        var out = Data()
        out.append(Protobuf.packedVarintField(2, mentions))
        if let parentFID = parentAuthorFID, let parentHash {
            var castId = Data()
            castId.append(Protobuf.varintField(1, parentFID))
            castId.append(Protobuf.bytesField(2, parentHash))
            out.append(Protobuf.bytesField(3, castId))
        }
        out.append(Protobuf.stringField(4, text))
        out.append(Protobuf.packedUInt32Field(5, mentionPositions))
        if let parentURL {
            out.append(Protobuf.stringField(7, parentURL))
        }
        // type 0 (regular cast) and format_version 0 are proto3 defaults
        // and are omitted, matching the Python reference bytes.
        return out
    }

    static func castAddData(
        fid: UInt64, timestamp: UInt32,
        text: String, mentions: [UInt64], mentionPositions: [UInt32],
        parentAuthorFID: UInt64?, parentHash: Data?, parentURL: String? = nil
    ) -> Data {
        let body = castAddBody(
            text: text, mentions: mentions, mentionPositions: mentionPositions,
            parentAuthorFID: parentAuthorFID, parentHash: parentHash, parentURL: parentURL
        )
        return messageData(type: 1, fid: fid, timestamp: timestamp, bodyField: 5, body: body)
    }

    // MARK: - Reaction (type 3 add, type 4 remove)

    /// ReactionBody fields: type 1 (1 like, 2 recast), target_cast_id 2.
    static func reactionData(
        fid: UInt64, timestamp: UInt32, reactionType: UInt64,
        targetAuthorFID: UInt64, targetHash: Data, remove: Bool
    ) -> Data {
        var target = Data()
        target.append(Protobuf.varintField(1, targetAuthorFID))
        target.append(Protobuf.bytesField(2, targetHash))
        var body = Data()
        body.append(Protobuf.varintField(1, reactionType))
        body.append(Protobuf.bytesField(2, target))
        return messageData(
            type: remove ? 4 : 3, fid: fid, timestamp: timestamp, bodyField: 7, body: body
        )
    }

    // MARK: - UserDataAdd (type 11)

    /// UserDataBody fields: type 1 (1 pfp, 2 display, 3 bio), value 2.
    static func userDataAddData(fid: UInt64, timestamp: UInt32, type: UInt64, value: String) -> Data {
        var body = Data()
        body.append(Protobuf.varintField(1, type))
        body.append(Protobuf.stringField(2, value))
        return messageData(type: 11, fid: fid, timestamp: timestamp, bodyField: 12, body: body)
    }

    // MARK: - KeyAdd (type 16)

    /// KeyAddBody fields: key 1, key_type 2, custody_signature 3,
    /// deadline 4, nonce 5, metadata 6, metadata_type 7,
    /// registration_tx_hash 8, scopes 9 (packed uint32), ttl 10.
    /// Metadata MUST be the ABI encoding of a single tuple
    /// (uint256,address,bytes,uint256) = 288 bytes with a leading 0x20
    /// offset word, NOT four flat fields (256 bytes). See EIP712.swift
    /// in the Python reference: abi_encode(["(uint256,address,bytes,uint256)"]).
    static func keyAddBody(
        signerPublicKey: Data, custodySignature: Data, deadline: UInt32,
        nonce: UInt32, metadata: Data, scopes: [UInt32], ttl: UInt32
    ) -> Data {
        var out = Data()
        out.append(Protobuf.bytesField(1, signerPublicKey))
        out.append(Protobuf.varintField(2, 1)) // key_type 1 = Ed25519
        out.append(Protobuf.bytesField(3, custodySignature))
        out.append(Protobuf.varintField(4, UInt64(deadline)))
        out.append(Protobuf.varintField(5, UInt64(nonce)))
        out.append(Protobuf.bytesField(6, metadata))
        out.append(Protobuf.varintField(7, 1)) // metadata_type 1
        // registration_tx_hash is empty and omitted (proto3 default).
        out.append(Protobuf.packedUInt32Field(9, scopes))
        out.append(Protobuf.varintField(10, UInt64(ttl)))
        return out
    }

    /// ABI-encode SignedKeyRequest metadata as a single tuple
    /// (uint256 requestFid, address requestSigner, bytes signature, uint256 deadline).
    /// Verified byte-identical against eth-abi (19 Nov 2026, 288 bytes for
    /// a 65-byte signature). Layout, 9 words:
    ///   [0] 0x20, offset to the tuple
    ///   [1] requestFid
    ///   [2] requestSigner (address, left-padded)
    ///   [3] 0x80, offset to the dynamic bytes field within the tuple
    ///   [4] deadline
    ///   [5] signature length (65)
    ///   [6..8] signature bytes, right-padded with zeros to 96 bytes
    static func signedKeyRequestMetadata(
        requestFid: UInt64, requestSigner: String, signature: Data, deadline: UInt64
    ) -> Data {
        var out = Data()
        out.append(Ethereum.abiEncodeUint256(32)) // offset to the tuple
        out.append(Ethereum.abiEncodeUint256(requestFid))
        out.append(Ethereum.abiEncodeAddress(requestSigner))
        out.append(Ethereum.abiEncodeUint256(128)) // offset to bytes within the tuple
        out.append(Ethereum.abiEncodeUint256(deadline))
        out.append(Ethereum.abiEncodeUint256(UInt64(signature.count)))
        out.append(signature)
        let remainder = signature.count % 32
        if remainder != 0 {
            out.append(Data(repeating: 0, count: 32 - remainder))
        }
        return out
    }

    static func keyAddData(
        fid: UInt64, timestamp: UInt32, signerPublicKey: Data,
        custodySignature: Data, deadline: UInt32, nonce: UInt32,
        metadata: Data, scopes: [UInt32], ttl: UInt32
    ) -> Data {
        let body = keyAddBody(
            signerPublicKey: signerPublicKey, custodySignature: custodySignature,
            deadline: deadline, nonce: nonce, metadata: metadata, scopes: scopes, ttl: ttl
        )
        return messageData(type: 16, fid: fid, timestamp: timestamp, bodyField: 19, body: body)
    }

    // MARK: - NativeOnboard (type 160) and PoW

    /// PoW: SHA256("hyper.onboard.pow:" || custody20 || anchor32 || nonce BE8).
    /// Target for 22 bits: hash[0] == 0, hash[1] == 0, hash[2] < 4.
    static func powHash(custody: Data, anchor: Data, nonce: UInt64) -> Data {
        var input = Data("hyper.onboard.pow:".utf8)
        input.append(custody)
        input.append(anchor)
        var nonceBytes = nonce.bigEndian
        input.append(Data(bytes: &nonceBytes, count: 8))
        return Data(SHA256.hash(data: input))
    }

    static func powTargetMet(hash: Data, bits: UInt32) -> Bool {
        let full = Int(bits / 8)
        let rest = Int(bits % 8)
        guard hash.count > full else { return false }
        for i in 0..<full where hash[i] != 0 { return false }
        if rest == 0 { return true }
        return hash[full] < (1 << (8 - rest))
    }

    /// Gate commitment: SHA256("hyper.onboard.pow.commitment:" || nonce BE8 || difficulty BE32).
    static func gateCommitment(nonce: UInt64, difficultyBits: UInt32) -> Data {
        var input = Data("hyper.onboard.pow.commitment:".utf8)
        var nonceBytes = nonce.bigEndian
        input.append(Data(bytes: &nonceBytes, count: 8))
        var bitsBytes = difficultyBits.bigEndian
        input.append(Data(bytes: &bitsBytes, count: 4))
        return Data(SHA256.hash(data: input))
    }

    /// Mine PoW. 22 bits is about 4 million hashes on average; on a phone
    /// this takes seconds with CryptoKit SHA256. Runs on a background task;
    /// check cancellation between batches. Returns the first passing nonce.
    static func minePoW(custody: Data, anchor: Data, bits: UInt32) throws -> UInt64 {
        var nonce: UInt64 = 0
        while true {
            if Task.isCancelled { throw CancellationError() }
            // Batch of 4096 before re-checking cancellation.
            for _ in 0..<4096 {
                if powTargetMet(hash: powHash(custody: custody, anchor: anchor, nonce: nonce), bits: bits) {
                    return nonce
                }
                nonce += 1
            }
            // Runs on a detached background task, so the UI stays responsive.
        }
    }

    /// HyperNativeOnboardBody fields: custody_address 1, custody_signature 2,
    /// anchor_block_height 3, anchor_block_hash 4, pow 5 (oneof gate_proof).
    /// PowSolution fields: nonce 1 (bytes, BE8), difficulty_bits 2.
    static func nativeOnboardBody(
        custody: Data, custodySignature: Data, anchorHeight: UInt64,
        anchorHash: Data, nonce: UInt64, difficultyBits: UInt32
    ) -> Data {
        var pow = Data()
        var nonceBytes = nonce.bigEndian
        pow.append(Protobuf.bytesField(1, Data(bytes: &nonceBytes, count: 8)))
        pow.append(Protobuf.varintField(2, UInt64(difficultyBits)))
        var out = Data()
        out.append(Protobuf.bytesField(1, custody))
        out.append(Protobuf.bytesField(2, custodySignature))
        out.append(Protobuf.varintField(3, anchorHeight))
        out.append(Protobuf.bytesField(4, anchorHash))
        out.append(Protobuf.bytesField(5, pow))
        return out
    }

    static func nativeOnboardData(
        timestamp: UInt32, custody: Data, custodySignature: Data,
        anchorHeight: UInt64, anchorHash: Data, nonce: UInt64, difficultyBits: UInt32
    ) -> Data {
        let body = nativeOnboardBody(
            custody: custody, custodySignature: custodySignature,
            anchorHeight: anchorHeight, anchorHash: anchorHash,
            nonce: nonce, difficultyBits: difficultyBits
        )
        // NativeOnboard has no signer: the outer Message carries an empty
        // signature and signature scheme 0, with hash = BLAKE3-20(data).
        return messageData(type: 160, fid: 0, timestamp: timestamp, bodyField: 1160, body: body)
    }
}
