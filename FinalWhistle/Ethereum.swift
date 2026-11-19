import Foundation
import CryptoSwift

/// Ethereum helpers: Keccak-256, addresses, and EIP-712 typed-data hashing.
/// Keccak is NOT NIST SHA-3: use CryptoSwift `SHA3(variant: .keccak256)`.
/// `.sha3_256` in CryptoSwift is NIST SHA-3 and gives the wrong answer here.
/// Verified against eth-account / eth-abi in the Python reference.
enum Ethereum {
    /// Keccak-256 of data.
    static func keccak256(_ data: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: [UInt8](data)))
    }

    static func keccak256(_ bytes: [UInt8]) -> [UInt8] {
        SHA3(variant: .keccak256).calculate(for: bytes)
    }

    /// Ethereum address (lowercase hex with 0x) for an uncompressed
    /// secp256k1 public key (65 bytes, 0x04 || x || y).
    /// Address = last 20 bytes of keccak256(x || y).
    static func address(fromUncompressedPublicKey key: Data) -> String? {
        guard key.count == 65, key.first == 0x04 else { return nil }
        let hash = keccak256(key.dropFirst())
        return "0x" + Data(hash.suffix(20)).hexString
    }

    // MARK: - ABI encoding (for EIP-712 struct hashing)

    static func abiEncodeUint256(_ value: UInt64) -> Data {
        var bytes = Data(repeating: 0, count: 32)
        var v = value
        for i in (24..<32).reversed() {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        return bytes
    }

    static func abiEncodeUint32(_ value: UInt32) -> Data {
        abiEncodeUint256(UInt64(value))
    }

    static func abiEncodeAddress(_ address: String) -> Data {
        guard let bytes = Data(hex: address), bytes.count == 20 else { return Data(repeating: 0, count: 32) }
        return Data(repeating: 0, count: 12) + bytes
    }

    static func abiEncodeBytes32(_ data: Data) -> Data {
        guard data.count == 32 else { return Data(repeating: 0, count: 32) }
        return data
    }

    /// Dynamic bytes / string: keccak256 of the value.
    static func abiEncodeBytes(_ data: Data) -> Data {
        keccak256(data)
    }

    // MARK: - EIP-712

    /// EIP-712 domain separator for a domain with name, version, chainId.
    /// domainSeparator = keccak256(abiEncode(
    ///   keccak256("EIP712Domain(string name,string version,uint256 chainId)"),
    ///   keccak256(name), keccak256(version), chainId))
    static func domainSeparator(name: String, version: String, chainId: UInt64) -> Data {
        let typeHash = keccak256(Data("EIP712Domain(string name,string version,uint256 chainId)".utf8))
        var encoded = Data()
        encoded.append(typeHash)
        encoded.append(keccak256(Data(name.utf8)))
        encoded.append(keccak256(Data(version.utf8)))
        encoded.append(abiEncodeUint256(chainId))
        return keccak256(encoded)
    }

    /// EIP-712 signing hash: keccak256(0x1901 || domainSeparator || hashStruct).
    static func eip712Hash(domainSeparator: Data, structHash: Data) -> Data {
        var input = Data([0x19, 0x01])
        input.append(domainSeparator)
        input.append(structHash)
        return keccak256(input)
    }

    /// HyperNativeOnboard struct hash.
    /// Type: "HyperNativeOnboard(address custody,uint64 anchor_block_height,bytes32 anchor_block_hash,bytes32 gate_commitment)"
    /// (field order and types from snap_onboard_throwaway.py, verified
    /// against farcasterorg/hypersnap src/native_registration.rs).
    static func hyperNativeOnboardStructHash(
        custody: String, anchorHeight: UInt64, anchorHash: Data, gateCommitment: Data
    ) -> Data {
        let typeHash = keccak256(Data("HyperNativeOnboard(address custody,uint64 anchor_block_height,bytes32 anchor_block_hash,bytes32 gate_commitment)".utf8))
        var encoded = Data()
        encoded.append(typeHash)
        encoded.append(abiEncodeAddress(custody))
        encoded.append(abiEncodeUint256(anchorHeight))
        encoded.append(abiEncodeBytes32(anchorHash))
        encoded.append(abiEncodeBytes32(gateCommitment))
        return keccak256(encoded)
    }

    /// KeyAdd struct hash.
    /// Type: "KeyAdd(uint256 fid,bytes key,uint32 keyType,uint32[] scopes,uint32 ttl,uint32 nonce,uint256 deadline)"
    static func keyAddStructHash(
        fid: UInt64, key: Data, keyType: UInt32, scopes: [UInt32], ttl: UInt32, nonce: UInt32, deadline: UInt64
    ) -> Data {
        let typeHash = keccak256(Data("KeyAdd(uint256 fid,bytes key,uint32 keyType,uint32[] scopes,uint32 ttl,uint32 nonce,uint256 deadline)".utf8))
        var scopesEncoded = Data()
        for scope in scopes { scopesEncoded.append(abiEncodeUint32(scope)) }
        var encoded = Data()
        encoded.append(typeHash)
        encoded.append(abiEncodeUint256(fid))
        encoded.append(abiEncodeBytes(key))
        encoded.append(abiEncodeUint32(keyType))
        encoded.append(keccak256(scopesEncoded))
        encoded.append(abiEncodeUint32(ttl))
        encoded.append(abiEncodeUint32(nonce))
        encoded.append(abiEncodeUint256(deadline))
        return keccak256(encoded)
    }

    /// SignedKeyRequest struct hash.
    /// Type: "SignedKeyRequest(uint256 requestFid,bytes key,uint256 deadline)"
    static func signedKeyRequestStructHash(requestFid: UInt64, key: Data, deadline: UInt64) -> Data {
        let typeHash = keccak256(Data("SignedKeyRequest(uint256 requestFid,bytes key,uint256 deadline)".utf8))
        var encoded = Data()
        encoded.append(typeHash)
        encoded.append(abiEncodeUint256(requestFid))
        encoded.append(abiEncodeBytes(key))
        encoded.append(abiEncodeUint256(deadline))
        return keccak256(encoded)
    }

    // MARK: - Low-S normalisation

    /// secp256k1 curve order n, and n/2, as big-endian bytes.
    static let curveOrder: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ]
    static let curveOrderHalf: [UInt8] = [
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    ]

    /// If s is high (s > n/2), return (n - s, flippedRecoveryId).
    /// libsecp256k1 recoverable signing does not normalise s; Ethereum
    /// verifiers expect low-s. Flipping s flips the recovery id bit.
    static func normaliseLowS(s: Data, recoveryId: UInt8) -> (s: Data, recoveryId: UInt8) {
        let sBytes = [UInt8](s)
        guard sBytes.count == 32 else { return (s, recoveryId) }
        // Lexicographic compare of equal-length big-endian integers.
        if sBytes.lexicographicallyPrecedes(curveOrderHalf) || sBytes == curveOrderHalf {
            return (s, recoveryId)
        }
        // n - s, byte by byte with borrow.
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for i in (0..<32).reversed() {
            let diff = Int(curveOrder[i]) - Int(sBytes[i]) - borrow
            if diff < 0 {
                result[i] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[i] = UInt8(diff)
                borrow = 0
            }
        }
        return (Data(result), recoveryId ^ 1)
    }
}
