import Foundation
import BLAKE3

/// BLAKE3, via the pinned blake3-swift package (0.2.2, exact).
/// Hypersnap message hashes are the first 20 bytes of BLAKE3 over the
/// serialized MessageData, hash scheme BLAKE3.
/// Test vector (official BLAKE3): hash of the empty input starts
/// af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262.
/// The unit test asserts that vector on first build; if it fails, the
/// BLAKE3 package is not producing correct output and nothing signed
/// with it can be trusted. Fallback if the wrapper ever breaks: vendor
/// the official C sources (BLAKE3-team/BLAKE3) as a local SPM C target.
enum Blake3 {
    static func hash(_ data: Data) -> Data {
        var hasher = BLAKE3()
        hasher.update(data: data)
        return hasher.finalizeData()
    }

    /// First 20 bytes of BLAKE3(data): the Farcaster message hash.
    static func hash20(_ data: Data) -> Data {
        Data(hash(data).prefix(20))
    }
}
