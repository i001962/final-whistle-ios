import Foundation
import P256K

/// secp256k1 custody keys, via the pinned P256K package (21-DOT-DEV
/// swift-secp256k1, 0.25.1, exact). CryptoKit P256 is NIST secp256r1 and
/// does NOT interoperate; do not use it here.
///
/// Verified against the P256K 0.25.1 source (cloned 19 Nov 2026):
/// - `P256K.Recovery.PrivateKey(dataRepresentation:format:)` builds a key
///   from a 32-byte scalar. Pass `.uncompressed` to get a 65-byte public key.
/// - `signature(for: Digest)` on Recovery.PrivateKey signs a PRE-COMPUTED
///   digest via secp256k1_ecdsa_sign_recoverable. Do NOT use the
///   `signature(for: Data)` overload: it SHA-256-hashes the input first,
///   which is wrong for an EIP-712 digest (already a Keccak hash).
/// - The digest argument is `P256K.HashDigest` (aka SHA256Digest), whose
///   public `init(_ output: [UInt8])` accepts ANY 32 bytes, despite the name.
/// - The returned signature is 65 bytes: r || s || recoveryId (0...3),
///   in `dataRepresentation`. It is NOT guaranteed low-s, so normalise
///   with Ethereum.normaliseLowS before use, and use v = recoveryId + 27.
enum CustodyKeys {
    enum KeyError: Error, LocalizedError {
        case invalidPrivateKey
        case invalidPublicKey
        case invalidDigest

        var errorDescription: String? {
            switch self {
            case .invalidPrivateKey: return "Invalid secp256k1 private key."
            case .invalidPublicKey: return "Invalid secp256k1 public key."
            case .invalidDigest: return "Digest must be exactly 32 bytes."
            }
        }
    }

    static func generatePrivateKey() throws -> Data {
        let key = try P256K.Recovery.PrivateKey(format: .uncompressed)
        return key.dataRepresentation
    }

    static func publicKeyUncompressed(privateKey: Data) throws -> Data {
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        return key.publicKey.dataRepresentation
    }

    static func address(privateKey: Data) throws -> String {
        let pub = try publicKeyUncompressed(privateKey: privateKey)
        guard let address = Ethereum.address(fromUncompressedPublicKey: pub) else {
            throw KeyError.invalidPublicKey
        }
        return address
    }

    /// Sign a 32-byte EIP-712 digest. Returns 65 bytes r || s || v,
    /// with v = 27 or 28, low-s normalised.
    static func signDigest(_ digest: Data, privateKey: Data) throws -> Data {
        guard digest.count == 32 else { throw KeyError.invalidDigest }
        let key = try P256K.Recovery.PrivateKey(dataRepresentation: privateKey, format: .uncompressed)
        let hashDigest = try P256K.HashDigest([UInt8](digest))
        let signature = key.signature(for: hashDigest)
        let bytes = [UInt8](signature.dataRepresentation)
        guard bytes.count == 65 else { throw KeyError.invalidPrivateKey }
        let (lowS, recoveryId) = Ethereum.normaliseLowS(
            s: Data(bytes[32..<64]), recoveryId: bytes[64]
        )
        var out = Data(bytes[0..<32])
        out.append(lowS)
        out.append(recoveryId + 27)
        return out
    }

    /// EIP-712 sign for a domain + struct hash. Returns r || s || v (65 bytes).
    static func signEIP712(
        domainName: String, domainVersion: String, chainId: UInt64,
        structHash: Data, privateKey: Data
    ) throws -> Data {
        let separator = Ethereum.domainSeparator(name: domainName, version: domainVersion, chainId: chainId)
        let digest = Ethereum.eip712Hash(domainSeparator: separator, structHash: structHash)
        return try signDigest(digest, privateKey: privateKey)
    }
}
