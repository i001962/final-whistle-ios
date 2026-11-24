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
    /// An inline emoji: `:packid:emojiconid:` in the text whose image
    /// is one of this cast's embeds. Client-side only (no protocol
    /// change): the shortcode resolves against the app's sticker
    /// catalog, and it only renders inline when the resolved URL is
    /// actually attached to this cast. Otherwise it stays literal text.
    case emoji(url: URL, alt: String)
}

/// A `:packid:emojiconid:` shortcode in the text. Pack and sticker ids
/// use the FIP label charset: `[a-z0-9_][a-z0-9_-]{0,31}`.
private let shortcodePattern = #":([a-z0-9_][a-z0-9_-]{0,31}):([a-z0-9_][a-z0-9_-]{0,31}):"#

extension Cast {
    /// The shortcodes in this cast's text that resolve to an image
    /// embed actually attached to the cast. Each entry is the
    /// shortcode's range in the raw text plus the resolved image URL.
    /// A shortcode with no matching embed is literal text, not emoji.
    var inlineEmojiMatches: [(range: Range<String.Index>, url: URL)] {
        guard let regex = try? NSRegularExpression(pattern: shortcodePattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var out: [(range: Range<String.Index>, url: URL)] = []
        for match in matches {
            guard match.numberOfRanges == 3,
                  let packRange = Range(match.range(at: 1), in: text),
                  let stickerRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range, in: text)
            else { continue }
            let packID = String(text[packRange])
            let stickerID = String(text[stickerRange])
            guard let url = StickerStore.shared.stickerURL(packID: packID, stickerID: stickerID),
                  imageEmbedURLs.contains(url)
            else { continue }
            out.append((range: fullRange, url: url))
        }
        return out
    }

    /// The embed URLs consumed by inline emoji in this cast. The
    /// embeds view skips these so a matched image is not also shown
    /// as a block below the text.
    var consumedInlineEmojiURLs: [URL] {
        inlineEmojiMatches.map(\.url)
    }

    /// True when the text is nothing but 1–3 inline emoji shortcodes
    /// (plus whitespace), all resolved to embeds. Per the FIP, those
    /// render large, at sticker size, instead of at line height.
    /// Four or more shortcodes render inline.
    var isShortcodeOnlyEmojiMessage: Bool {
        let matches = inlineEmojiMatches
        guard (1...3).contains(matches.count) else { return false }
        var remainder = text
        // The match ranges point into the original text. Replacing
        // front to back shifts the string, so the second range lands
        // past the end of the shortened remainder and the app
        // crashes (EXC_BAD_ACCESS) on any cast with two inline
        // emoji. Replacing back to front keeps every earlier range
        // valid, because each cut only moves text after it.
        for match in matches.reversed() {
            remainder = remainder.replacingCharacters(in: match.range, with: "")
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
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
            return Self.markdownLinkify(string)
        }.flatMap { piece -> [CastTextSegment] in
            guard case .text(let string) = piece else { return [piece] }
            return Self.linkify(string)
        }.flatMap { piece -> [CastTextSegment] in
            guard case .text(let string) = piece else { return [piece] }
            return Self.emojify(string, embeds: imageEmbedURLs)
        }
    }

    /// Split a plain-text piece on Markdown links `[label](url)`.
    /// A Markdown link becomes a link segment whose display is the
    /// label, not the URL — the "if you know you know" way to write
    /// a labeled link. Anything that is not a well-formed Markdown
    /// link stays literal text, so a stray `[` or `(` never breaks
    /// the render. Runs before linkify, so the URL inside the
    /// parens is not also picked up as a bare link. The label is
    /// display text only: it is not scanned for shortcodes.
    private static func markdownLinkify(_ text: String) -> [CastTextSegment] {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#) else {
            return [.text(text)]
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }
        var out: [CastTextSegment] = []
        var cursor = text.startIndex
        for match in matches {
            guard match.numberOfRanges == 3,
                  let fullRange = Range(match.range, in: text),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text)
            else { continue }
            if fullRange.lowerBound > cursor {
                out.append(.text(String(text[cursor..<fullRange.lowerBound])))
            }
            let label = String(text[labelRange])
            let raw = String(text[urlRange])
            let href = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: href) {
                out.append(.link(url: url, display: label))
            } else {
                out.append(.text(String(text[fullRange])))
            }
            cursor = fullRange.upperBound
        }
        if cursor < text.endIndex {
            out.append(.text(String(text[cursor..<text.endIndex])))
        }
        return out.isEmpty ? [.text(text)] : out
    }

    /// Split a plain-text piece on `:packid:emojiconid:` shortcodes.
    /// A shortcode becomes an emoji segment only when it resolves
    /// (via the sticker catalog) to a URL that is actually one of
    /// this cast's image embeds. Anything else stays literal text.
    private static func emojify(_ text: String, embeds: [URL]) -> [CastTextSegment] {
        guard let regex = try? NSRegularExpression(pattern: shortcodePattern),
              !embeds.isEmpty
        else { return [.text(text)] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }
        var out: [CastTextSegment] = []
        var cursor = text.startIndex
        for match in matches {
            guard match.numberOfRanges == 3,
                  let fullRange = Range(match.range, in: text),
                  let packRange = Range(match.range(at: 1), in: text),
                  let stickerRange = Range(match.range(at: 2), in: text)
            else { continue }
            let packID = String(text[packRange])
            let stickerID = String(text[stickerRange])
            guard let url = StickerStore.shared.stickerURL(packID: packID, stickerID: stickerID),
                  embeds.contains(url)
            else { continue }
            if fullRange.lowerBound > cursor {
                out.append(.text(String(text[cursor..<fullRange.lowerBound])))
            }
            out.append(.emoji(url: url, alt: String(text[fullRange])))
            cursor = fullRange.upperBound
        }
        if cursor < text.endIndex {
            out.append(.text(String(text[cursor..<text.endIndex])))
        }
        return out.isEmpty ? [.text(text)] : out
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
            case .emoji(_, let alt):
                // The AttributedString path cannot hold an image, so
                // an emoji renders as its shortcode here. CastTextView
                // uses the segment path below to draw the real image
                // inline; this is the fallback if it is not loaded.
                var run = AttributedString(alt)
                run.font = font
                run.foregroundColor = textColor
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

/// A cast's text as a Text view, with tappable @mentions and links,
/// and inline emoji: a `:packid:emojiconid:` shortcode whose image is
/// one of the cast's embeds renders as the image itself, at line
/// height, instead of as text. The image loads asynchronously; while
/// it loads (or if it fails) the shortcode shows as text, per the FIP.
/// A message that is only 1–3 shortcodes renders no text at all here —
/// the embeds view below shows those stickers large instead.
struct CastTextView: View {
    let cast: Cast
    var font: Font = .body
    var textColor: Color = .fwText
    /// The author's name, shown inline at the start of the message
    /// (the room's IRC-style line: the name and the message share
    /// one line and wrap together). Nil means no name prefix.
    var authorName: String? = nil
    /// The author's color for that name. A stable per-author color,
    /// so a name reads as who it is at a glance.
    var authorColor: Color = .fwText
    /// Loaded emoji images, keyed by URL. Filled by the task below.
    @State private var emojiImages: [URL: UIImage] = [:]

    /// Inline emoji sit at line height: 1.2em on a 17pt body line.
    private var emojiHeight: CGFloat { 20 }

    /// The author's name as the start of the message line: the name
    /// in their color and semibold, then a space. Empty when there
    /// is no author prefix.
    private var authorPrefix: Text {
        guard let authorName else { return Text("") }
        return Text(authorName)
            .font(font)
            .fontWeight(.semibold)
            .foregroundColor(authorColor)
            + Text(" ")
    }

    var body: some View {
        Group {
            if cast.isShortcodeOnlyEmojiMessage {
                // Nothing to show as text: the stickers render large
                // in the embeds view. The author's name still shows
                // on its own line, so a sticker-only message is
                // attributed. An empty Text keeps the layout from
                // collapsing oddly in a VStack.
                authorPrefix
            } else {
                textWithInlineEmoji
            }
        }
        .task(id: cast.hash) {
            await loadEmojiImages()
        }
    }

    /// The segments as one Text, with emoji segments drawn as the
    /// loaded image inline. Text and image parts concatenate with
    /// `+`, and AttributedString runs keep mentions and links
    /// tappable. An emoji whose image has not loaded yet shows its
    /// shortcode as text. The author's name (when set) leads the
    /// line, so the name and the message share one flowing line.
    private var textWithInlineEmoji: Text {
        var result = authorPrefix
        for segment in cast.textSegments {
            switch segment {
            case .text(let string):
                var run = AttributedString(string)
                run.font = font
                run.foregroundColor = textColor
                result = result + Text(run)
            case .mention(let fid, let username):
                var run = AttributedString("@\(username)")
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                run.link = URL(string: "fw://mention/\(fid.value)")
                result = result + Text(run)
            case .channel(let name):
                var run = AttributedString("/\(name)")
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                result = result + Text(run)
            case .link(let url, let display):
                var run = AttributedString(display)
                run.font = font
                run.foregroundColor = .fwAccentSoft
                run.underlineStyle = nil
                run.link = url
                result = result + Text(run)
            case .emoji(let url, let alt):
                if let image = emojiImages[url] {
                    // The image is already resized to line height
                    // when loaded, so a plain Image renders inline
                    // at the right size. No view modifiers here: a
                    // modified Image is a generic View, and Text has
                    // no initializer that takes one.
                    result = result + Text(Image(uiImage: image))
                } else {
                    var run = AttributedString(alt)
                    run.font = font
                    run.foregroundColor = textColor
                    result = result + Text(run)
                }
            }
        }
        return result
    }

    /// Fetch the emoji images for this cast's segments. Cached by
    /// URLSession, so a sticker seen once does not refetch on scroll.
    /// Each image is resized to line height on load, so the Text
    /// below can use a plain Image (a modified Image is a generic
    /// View, and Text cannot take one).
    private func loadEmojiImages() async {
        let urls = Set(cast.textSegments.compactMap { segment -> URL? in
            if case .emoji(let url, _) = segment { return url }
            return nil
        })
        for url in urls where emojiImages[url] == nil {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { continue }
            emojiImages[url] = resizedForInline(image)
        }
    }

    /// Scale an image down to fit in an emojiHeight square, keeping
    /// its aspect ratio. Small images are left alone, never upscaled.
    private func resizedForInline(_ image: UIImage) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(emojiHeight / size.width, emojiHeight / size.height)
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
