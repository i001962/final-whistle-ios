import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import CryptoKit

/// Hypersnap writes go ONLY via gRPC SubmitMessage to
/// grpc.castrater.xyz:3383, plaintext. hypersnap.castrater.xyz:3383 is
/// Cloudflare-proxied and drops raw gRPC, so never use it here.
/// Reads go via HTTPS (FeedService).
///
/// No generated protobuf stubs: the app hand-encodes the few request
/// messages it needs (Protobuf.swift, FarcasterMessages.swift) and calls
/// grpc-swift 2's generic unary API with an identity Data serializer.
/// The .proto files are vendored in Protos/ so the field numbers can be
/// checked against the source. This avoids a protoc / codegen step on the
/// Mac, at the cost of hand-maintained encoding, which the unit tests
/// pin with byte-exact vectors from the Python protobuf library.
///
/// Service name: the protos declare no package, so the fully qualified
/// service is just "HubService": /HubService/SubmitMessage etc.
enum HypersnapClient {
    static let service = "HubService"

    // MARK: - Identity Data serializer

    struct DataSerializer: MessageSerializer {
        func serialize<Bytes: GRPCContiguousBytes>(_ message: Data) throws -> Bytes {
            Bytes(message)
        }
    }

    struct DataDeserializer: MessageDeserializer {
        func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> Data {
            Data(bytes)
        }
    }

    enum ClientError: Error, LocalizedError {
        case rpcFailed(String)
        case emptyResponse
        case signerNotFound

        var errorDescription: String? {
            switch self {
            case .rpcFailed(let message): return "Hypersnap request failed: \(message)"
            case .emptyResponse: return "Hypersnap returned an empty response."
            case .signerNotFound: return "Signer not found for this FID."
            }
        }
    }

    // MARK: - Generic unary call

    private static func unary(method: String, request: Data) async throws -> Data {
        try await withGRPCClient(
            transport: .http2NIOTS(
                target: .dns(host: FeedService.grpcHost, port: FeedService.grpcPort),
                transportSecurity: .plaintext
            )
        ) { client in
            let response = try await client.unary(
                request: ClientRequest(message: request),
                descriptor: MethodDescriptor(fullyQualifiedService: service, method: method, type: .unary),
                serializer: DataSerializer(),
                deserializer: DataDeserializer(),
                options: CallOptions.defaults,
                onResponse: { response in try response.message }
            )
            return response
        }
    }

    // MARK: - Requests

    /// NativeAccountRequest: fid 1 (uint64, omit when 0), custody_address 2 (bytes).
    /// Pass exactly one of fid or custody, never both.
    static func nativeAccountRequest(fid: UInt64?, custody: Data?) -> Data {
        var out = Data()
        if let fid, fid != 0 { out.append(Protobuf.varintField(1, fid)) }
        if let custody { out.append(Protobuf.bytesField(2, custody)) }
        return out
    }

    /// GetNativeAccount returns NativeRegistrationRecord: fid 1, registration 2, block_number 3.
    static func nativeAccountFID(from response: Data) throws -> UInt64 {
        var reader = ProtobufReader(data: response)
        for field in try reader.readFields() {
            if field.field == 1, let value = field.varint { return value }
        }
        throw ClientError.emptyResponse
    }

    /// GetNativeAccount by custody. Returns nil when the node reports NOT_FOUND
    /// (no FID for that custody yet). Any other RPC error is thrown.
    static func fidForCustody(_ custody: Data) async throws -> UInt64? {
        do {
            let response = try await unary(method: "GetNativeAccount", request: nativeAccountRequest(fid: nil, custody: custody))
            return try nativeAccountFID(from: response)
        } catch let error as RPCError where error.code == .notFound {
            return nil
        }
    }

    static func fidForFID(_ fid: UInt64) async throws -> UInt64? {
        do {
            let response = try await unary(method: "GetNativeAccount", request: nativeAccountRequest(fid: fid, custody: nil))
            return try nativeAccountFID(from: response)
        } catch let error as RPCError where error.code == .notFound {
            return nil
        }
    }

    /// NativeRegistrationInfo: active 1 (bool varint), next_block 2,
    /// anchor_block_height 3, anchor_block_hash 4 (bytes),
    /// min_difficulty_bits 5, anchor_window 6, first_native_fid 7.
    struct RegistrationInfo {
        let active: Bool
        let nextBlock: UInt64
        let anchorHeight: UInt64
        let anchorHash: Data
        let minDifficultyBits: UInt32
        let anchorWindow: UInt64
        let firstNativeFID: UInt64
    }

    static func registrationInfo() async throws -> RegistrationInfo {
        // GetInfoRequest is an empty message.
        let response = try await unary(method: "GetNativeRegistrationInfo", request: Data())
        var reader = ProtobufReader(data: response)
        var active = false
        var nextBlock: UInt64 = 0
        var anchorHeight: UInt64 = 0
        var anchorHash = Data()
        var bits: UInt32 = 0
        var window: UInt64 = 0
        var firstFID: UInt64 = 0
        for field in try reader.readFields() {
            switch field.field {
            case 1: active = (field.varint ?? 0) != 0
            case 2: nextBlock = field.varint ?? 0
            case 3: anchorHeight = field.varint ?? 0
            case 4: anchorHash = field.bytes ?? Data()
            case 5: bits = UInt32(field.varint ?? 0)
            case 6: window = field.varint ?? 0
            case 7: firstFID = field.varint ?? 0
            default: break
            }
        }
        return RegistrationInfo(
            active: active, nextBlock: nextBlock, anchorHeight: anchorHeight,
            anchorHash: anchorHash, minDifficultyBits: bits, anchorWindow: window,
            firstNativeFID: firstFID
        )
    }

    /// SignersByFidRequest: fid 1. Response: signers 1 (repeated Signer),
    /// each Signer has key 2 (bytes). Returns true when the given public key
    /// appears for the FID.
    static func signerIsActive(fid: UInt64, signerPublicKey: Data) async throws -> Bool {
        var request = Data()
        request.append(Protobuf.varintField(1, fid))
        let response = try await unary(method: "GetSignersByFid", request: request)
        var reader = ProtobufReader(data: response)
        for field in try reader.readFields() {
            guard field.field == 1, let signerBytes = field.bytes else { continue }
            var signer = ProtobufReader(data: signerBytes)
            for signerField in try signer.readFields() {
                if signerField.field == 2, signerField.bytes == signerPublicKey { return true }
            }
        }
        return false
    }

    /// SubmitMessage. Returns the message hash (hex, with 0x) of the submitted message.
    /// The response is the submitted Message; its hash field (2) is read back.
    @discardableResult
    static func submitMessage(_ message: Data) async throws -> String {
        let response = try await unary(method: "SubmitMessage", request: message)
        var reader = ProtobufReader(data: response)
        for field in try reader.readFields() {
            if field.field == 2, let hash = field.bytes {
                return "0x" + hash.hexString
            }
        }
        // Fall back to the hash of the data we sent: MessageData bytes are
        // field 7 of the response, and BLAKE3-20 of them is the hash.
        for field in try ProtobufReader(data: response).readFields() {
            if field.field == 7, let dataBytes = field.bytes {
                return "0x" + Blake3.hash20(dataBytes).hexString
            }
        }
        throw ClientError.emptyResponse
    }

    // MARK: - Signed writes (Ed25519 signer)

    /// Sign MessageData with the Ed25519 signer and submit it.
    /// Returns the cast/message hash (hex with 0x).
    static func submitSigned(
        data: Data, fid: UInt64, signerSeed: Data
    ) async throws -> String {
        let signer = try Ed25519Signer(seed: signerSeed)
        let hash = Blake3.hash20(data)
        let signature = try signer.sign(hash)
        let message = FarcasterMessages.message(
            data: data, signerPublicKey: signer.publicKey, signature: signature, signatureScheme: 1
        )
        return try await submitMessage(message)
    }
}

/// Ed25519 signer from a 32-byte seed, via CryptoKit. The signer key posts,
/// reacts, and updates the profile. It cannot be imported into MetaMask:
/// it is not an Ethereum key.
struct Ed25519Signer {
    private let key: Curve25519.Signing.PrivateKey

    var publicKey: Data { key.publicKey.rawRepresentation }

    init(seed: Data) throws {
        guard seed.count == 32 else { throw HypersnapClient.ClientError.signerNotFound }
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    init() {
        key = Curve25519.Signing.PrivateKey()
    }

    var seed: Data { key.rawRepresentation }

    func sign(_ hash: Data) throws -> Data {
        try key.signature(for: hash)
    }
}
