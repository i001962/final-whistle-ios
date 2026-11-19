import Foundation

/// Minimal protobuf wire encoder/decoder for the Farcaster messages this app
/// needs. No generated stubs: the .proto files live in Protos/ (from
/// farcasterorg/hypersnap, proto/definitions/), and the field numbers below
/// are taken from them and from the verified Python reference
/// (~/workspace/hypersnap-peel/hs.py, ~/workspace/snap-onboard-test/).
///
/// Byte-level checks against the Python protobuf library (19 Nov 2026):
///   CastAddBody(text: " hello", mentions: [4163, 999], positions: [0, 6])
///     -> 1204c320e70722062068656c6c6f2a020006
///   ReactionBody(like, target fid 8106, hash 0af189...)
///     -> 0801121908aa3f12140af1897505c73ec1ae58cd43c0b59b95a8ac0c61
///   KeyAddBody scopes [1,2,3,4,5,6,11,12] encodes packed as 4a080102030405060b0c
/// Repeated numeric fields are packed (wire type 2), as proto3 requires.
/// The unit tests in FinalWhistleTests assert these exact vectors.
enum Protobuf {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while true {
            if value < 0x80 {
                out.append(UInt8(value))
                return out
            }
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
    }

    static func tag(field: Int, wire: Int) -> Data {
        varint(UInt64((field << 3) | wire))
    }

    static func varintField(_ field: Int, _ value: UInt64) -> Data {
        tag(field: field, wire: 0) + varint(value)
    }

    static func bytesField(_ field: Int, _ value: Data) -> Data {
        tag(field: field, wire: 2) + varint(UInt64(value.count)) + value
    }

    static func stringField(_ field: Int, _ value: String) -> Data {
        bytesField(field, Data(value.utf8))
    }

    /// Packed repeated varint field (proto3 default for repeated numerics).
    static func packedVarintField(_ field: Int, _ values: [UInt64]) -> Data {
        guard !values.isEmpty else { return Data() }
        var packed = Data()
        for value in values { packed.append(varint(value)) }
        return tag(field: field, wire: 2) + varint(UInt64(packed.count)) + packed
    }

    static func packedUInt32Field(_ field: Int, _ values: [UInt32]) -> Data {
        packedVarintField(field, values.map(UInt64.init))
    }
}

/// Minimal protobuf reader: enough to decode the small gRPC responses this
/// app needs (NativeRegistrationRecord.fid, NativeRegistrationInfo,
/// SignersByFidResponse.signers[].key, Message.hash).
struct ProtobufReader {
    let data: Data
    private(set) var offset: Int = 0

    var isAtEnd: Bool { offset >= data.count }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 70 else { throw ProtobufError.malformed }
        }
        throw ProtobufError.truncated
    }

    mutating func readTag() throws -> (field: Int, wire: Int) {
        let value = try readVarint()
        return (Int(value >> 3), Int(value & 0x07))
    }

    mutating func readBytes() throws -> Data {
        let length = Int(try readVarint())
        guard offset + length <= data.count else { throw ProtobufError.truncated }
        let bytes = data.subdata(in: offset..<(offset + length))
        offset += length
        return bytes
    }

    mutating func skip(wire: Int) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: offset += 8
        case 2: _ = try readBytes()
        case 5: offset += 4
        default: throw ProtobufError.malformed
        }
        guard offset <= data.count else { throw ProtobufError.truncated }
    }

    /// Read all fields into a list, keeping raw bytes for embedded messages.
    mutating func readFields() throws -> [(field: Int, wire: Int, varint: UInt64?, bytes: Data?)] {
        var fields: [(field: Int, wire: Int, varint: UInt64?, bytes: Data?)] = []
        while !isAtEnd {
            let (field, wire) = try readTag()
            switch wire {
            case 0:
                fields.append((field, wire, try readVarint(), nil))
            case 2:
                fields.append((field, wire, nil, try readBytes()))
            default:
                try skip(wire: wire)
            }
        }
        return fields
    }
}

enum ProtobufError: Error, LocalizedError {
    case malformed
    case truncated

    var errorDescription: String? {
        switch self {
        case .malformed: return "Malformed protobuf data."
        case .truncated: return "Truncated protobuf data."
        }
    }
}
