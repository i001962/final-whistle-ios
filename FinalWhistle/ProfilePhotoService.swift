import Foundation
import UIKit

/// Uploads a picked profile photo to Castrater Storage's Final
/// Whistle pfp endpoint and returns its public URL, so the URL can
/// go into a UserDataAdd (type 1, pfp) via IdentityStore.setPFP.
/// The full contract lives in docs/pfp-upload-api.md — this file
/// implements the app side of it.
///
/// A Farcaster pfp is a URL, not an upload, so the image has to live
/// somewhere public first. This endpoint is that somewhere: one pfp
/// per FID, no payment, the operator covers the storage. The API key
/// identifies the app; the FID's signer signature is what authorizes
/// an upload for a given FID. The key ships in the build via
/// Secrets.swift (gitignored, never committed) — see
/// Secrets.example.swift.
enum ProfilePhotoService {
    static let pfpEndpoint = URL(string: "https://storage.castrater.xyz/v1/files/pfp")!

    /// The exact bytes the FID's signer signs: binds the upload to
    /// one FID and one exact image. The server verifies this against
    /// the signer public key registered for the FID on Hypersnap.
    static func signatureMessage(fid: UInt64, sha256Hex: String) -> Data {
        Data("final-whistle-pfp:\(fid):\(sha256Hex)".utf8)
    }

    /// Square-crop and shrink a picked photo to a 512px JPEG. PFPs are
    /// shown at 32–72px in the app, so 512 is plenty and keeps the
    /// upload small.
    static func preparedJPEG(from image: UIImage) -> Data? {
        let side: CGFloat = 512
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = max(side / size.width, side / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let square = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return square.jpegData(compressionQuality: 0.85)
    }

    /// The pfp multipart body, kept pure so the tests can check its
    /// shape without touching the network.
    static func pfpMultipartBody(
        jpeg: Data, fid: UInt64, signerPublicKeyHex: String,
        sha256Hex: String, signatureHex: String, boundary: String
    ) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        field("fid", "\(fid)")
        field("signer_public_key", signerPublicKeyHex)
        field("sha256", sha256Hex)
        field("signature", signatureHex)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"pfp.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Upload the prepared JPEG as this FID's pfp. Returns the public
    /// URL, stable per FID.
    static func uploadPFP(
        jpeg: Data, fid: UInt64, signerPublicKeyHex: String,
        sha256Hex: String, signatureHex: String
    ) async throws -> String {
        guard !Secrets.pfpAPIKey.isEmpty else { throw UploadError.notConfigured }
        var request = URLRequest(url: pfpEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Secrets.pfpAPIKey)", forHTTPHeaderField: "Authorization")
        let boundary = "fw-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(
            for: request,
            from: pfpMultipartBody(
                jpeg: jpeg, fid: fid, signerPublicKeyHex: signerPublicKeyHex,
                sha256Hex: sha256Hex, signatureHex: signatureHex, boundary: boundary
            )
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UploadError.badResponse
        }
        struct PFPUploadResponse: Decodable {
            let url: String
        }
        guard let decoded = try? JSONDecoder().decode(PFPUploadResponse.self, from: data),
              decoded.url.hasPrefix("https://") else {
            throw UploadError.badResponse
        }
        return decoded.url
    }

    enum UploadError: Error, LocalizedError {
        case notConfigured
        case badResponse

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Photo upload is not configured yet (no API key in this build)."
            case .badResponse:
                return "The photo upload did not return a link."
            }
        }
    }
}
