import Foundation
import SwiftUI

// MARK: - Cast text with mentions put back (Quilcast shared.ts castText)

/// A cast's display text, split into pieces: plain text, an @mention, a
/// /channel, or a bare link. Hypersnap leaves mentions OUT of `text` and
/// gives their UTF-8 byte offsets instead (mentioned_profiles +
/// mentioned_profiles_ranges, zero-width ranges = insertion points), so
/// the raw text reads broken — "today is  birthday" — until the names
/// are spliced back in at their offsets. Channels work the same way.
/// Links are detected in the plain pieces (NSDataDetector), so a URL
/// pasted in the text is tappable without being a separate embed.
enum CastTextSegment: Hashable {
    case text(String)
    case mention(fid: FID, username: String)
    case channel(name: String)
    case link(url: URL, display: String)
}

extension Cast {
    /// The cast's text as it reads, with @mentions and /channels spliced
    /// back in at their byte offsets and bare links split out. Built on
    /// UTF-8 bytes, exactly like Quilcast's castText (TextEncoder /
    /// TextDecoder): String indices would silently misplace a mention
    /// after any multi-byte character.
    var textSegments: [CastTextSegment] {
        let bytes = [UInt8](text.utf8)
        struct Insertion {
            let offset: Int
            let end: Int // bytes the insertion replaces; == offset for a pure insertion
            let segment: CastTextSegment
            let order: Int
        }
        var insertions: [Insertion] = []
        for (i, range) in mentionedProfilesRanges.enumerated() {
            guard i < mentionedProfiles.count,
                  let username = mentionedProfiles[i].username, !username.isEmpty
            else { continue }
            let start = max(0, range.start)
            guard start <= bytes.count else { continue }
            let end = max(start, min(range.end, bytes.count))
            insertions.append(Insertion(
                offset: start, end: end,
                segment: .mention(fid: mentionedProfiles[i].fid, username: username),
                order: insertions.count
            ))
        }
        for (i, range) in mentionedChannelsRanges.enumerated() {
            guard i < mentionedChannels.count,
                  let name = mentionedChannels[i].name ?? mentionedChannels[i].id, !name.isEmpty
            else { continue }
            let start = max(0, range.start)
            guard start <= bytes.count else { continue }
            let end = max(start, min(range.end, bytes.count))
            insertions.append(Insertion(
                offset: start, end: end,
                segment: .channel(name: name),
                order: insertions.count
            ))
        }
        insertions.sort { ($0.offset, $0.order) < ($1.offset, $1.order) }

        var pieces: [CastTextSegment] = []
        var cursor = 0
        for insertion in insertions {
            if insertion.offset > cursor {
                let run = bytes[cursor..<insertion.offset]
                if !run.isEmpty { pieces.append(.text(String(decoding: run, as: UTF8.self))) }
            }
            pieces.append(insertion.segment)
            cursor = max(cursor, insertion.end)
        }
        if cursor < bytes.count {
            pieces.append(.text(String(decoding: bytes[cursor...], as: UTF8.self)))
        }
        return pieces.flatMap { piece -> [CastTextSegment] in
            guard case .text(let string) = piece else { return [piece] }
            return Self.linkify(string)
        }
    }

    /// The segments as one AttributedString: mentions and channels in the
    /// accent colour, links as links. A mention's link is the in-app
    /// `fw://mention/<fid>` URL, intercepted by the openURL environment
    /// in ContentView, which pushes that user's profile. A bare link's
    /// display is shortened (Quilcast shortUrl) but links to the full URL.
    func attributedText(font: Font = .body, textColor: Color = .fwText) -> AttributedString {
        var result = AttributedString()
        for segment in textSegments {
            switch segment {
            case .text(let string):
                var run = AttributedString(string)
                run.font = font
                run.foregroundColor = textColor
                result.append(run)
            case .mention(let fid, let username):
                var run = AttributedString("@\(username)")
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                run.link = URL(string: "fw://mention/\(fid.value)")
                result.append(run)
            case .channel(let name):
                var run = AttributedString("/\(name)")
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                result.append(run)
            case .link(let url, let display):
                var run = AttributedString(display)
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                run.link = url
                result.append(run)
            }
        }
        return result
    }

    private static func linkify(_ text: String) -> [CastTextSegment] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return [.text(text)]
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else { return [.text(text)] }
        var out: [CastTextSegment] = []
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if range.lowerBound > cursor {
                out.append(.text(String(text[cursor..<range.lowerBound])))
            }
            let raw = String(text[range])
            let href = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: href) {
                out.append(.link(url: url, display: shortURLString(raw)))
            } else {
                out.append(.text(raw))
            }
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            out.append(.text(String(text[cursor..<text.endIndex])))
        }
        return out
    }

    /// Quilcast shortUrl: scheme and www off, 40 characters max.
    private static func shortURLString(_ string: String) -> String {
        var shortened = string
        if let range = shortened.range(of: #"^https?://(www\.)?"#, options: .regularExpression) {
            shortened.removeSubrange(range)
        }
        if shortened.count > 40 { shortened = String(shortened.prefix(40)) + "…" }
        return shortened
    }
}

/// A cast's text as a Text view, with tappable @mentions and links.
struct CastTextView: View {
    let cast: Cast
    var font: Font = .body
    var textColor: Color = .fwText

    var body: some View {
        Text(cast.attributedText(font: font, textColor: textColor))
    }
}
