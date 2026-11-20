import Foundation
import UIKit

/// Hosts a picked profile photo and returns its public URL, so the
/// URL can go into a UserDataAdd (type 1, pfp) via
/// IdentityStore.setPFP. A Farcaster pfp is a URL, not an upload —
/// the image has to live somewhere public first.
///
/// v1 host is catbox.moe: free, no key, anonymous file upload with
/// direct links. One constant to swap when Final Whistle gets its own
/// upload endpoint on final-whistle.app — the rest of the flow
/// (picker → resize → upload → UserDataAdd → refresh) does not care
/// where the bytes live.
enum ProfilePhotoService {
    static let uploadURL = URL(string: "https://catbox.moe/user/api.php")!

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

    /// The catbox multipart body, kept pure so the tests can check its
    /// shape without touching the network.
    static func multipartBody(jpeg: Data, boundary: String) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\n")
        append("fileupload\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"pfp.jpg\"\r\n")
        append("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Upload the prepared JPEG. Returns the public file URL.
    static func upload(jpeg: Data) async throws -> String {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        let boundary = "fw-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(
            for: request, from: multipartBody(jpeg: jpeg, boundary: boundary)
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UploadError.badResponse
        }
        let url = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") else { throw UploadError.badResponse }
        return url
    }

    enum UploadError: Error, LocalizedError {
        case badResponse

        var errorDescription: String? {
            switch self {
            case .badResponse: return "The photo upload did not return a link."
            }
        }
    }
}
