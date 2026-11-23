import SwiftUI
import UIKit

/// The attribute key carrying an inline emoji's shortcode on its
/// attachment character. The shortcode lives in the attribute, not
/// on the attachment object: a UITextView copies the attributed
/// string into its text storage, and the copy drops an
/// NSTextAttachment subclass (and its shortcode with it) — and
/// overriding copy(with:) does not compile, because NSTextAttachment
/// exposes no overridable copy to Swift. Attributes survive the
/// copy, so the shortcode rides on the character, not the object.
private let emojiShortcodeAttributeKey = NSAttributedString.Key("FinalWhistleEmojiShortcode")

/// The shortcode shape, shared with CastText's renderer: a pack id
/// and an emoji id, each starting with a letter, digit or
/// underscore. The editor and the reader use the same delimiter,
/// so what you type is what the room and the feed render.
private let wysiwygShortcodePattern = #":([a-z0-9_][a-z0-9_-]{0,31}):([a-z0-9_][a-z0-9_-]{0,31}):"#

/// The emoji image cache, shared so a fetched image is available to
/// every editor without refetching. It also tracks which URLs are
/// already being fetched, so a rebuild does not start a second
/// fetch for the same image. The mutable state is guarded by an
/// NSLock, so the shared instance is thread-safe; the
/// `nonisolated(unsafe)` is Swift 6's way of saying that, the same
/// pattern StickerStore and ImageCache use.
final class SharedEmojiImageCache {
    nonisolated(unsafe) static let shared = SharedEmojiImageCache()
    private var cache: [URL: UIImage] = [:]
    private var inflight: Set<URL> = []
    private let lock = NSLock()
    private init() {}

    func image(for url: URL) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        return cache[url]
    }

    func set(_ image: UIImage, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        cache[url] = image
    }

    /// Mark a URL as being fetched. Returns false when it is already
    /// in flight, so the caller does not start a second fetch.
    func beginFetch(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !inflight.contains(url) else { return false }
        inflight.insert(url)
        return true
    }

    func endFetch(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        inflight.remove(url)
    }
}

/// A text editor that shows inline emoji as the emoji itself, not
/// the delimiter. WYSIWYG: while you write, `:banny:goal:` appears
/// as the goal picture sitting in the sentence, at line height.
/// The underlying text is still the plain text with shortcodes —
/// that is what gets posted, so the reader renders it the same way.
/// The shortcode is the emoji (inline, looked up by pack and emoji
/// id, the form the FIP will carry); the image the shortcode
/// resolves to is the sticker art (the embed). The two stay
/// separate: the text carries the reference, the embeds carry the art.
struct WYSIWYGEditor: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    /// Single-line mode (the room): Return sends instead of a newline.
    var isSingleLine: Bool = false
    var onCommit: (() -> Void)? = nil
    /// Focus, driven by the parent (the composer autofocuses the
    /// editor when it appears, so the keyboard is already up).
    @Binding var isFocused: Bool

    init(
        text: Binding<String>,
        placeholder: String = "",
        font: UIFont = .preferredFont(forTextStyle: .body),
        textColor: UIColor = .label,
        isSingleLine: Bool = false,
        onCommit: (() -> Void)? = nil,
        isFocused: Binding<Bool>
    ) {
        self._text = text
        self.placeholder = placeholder
        self.font = font
        self.textColor = textColor
        self.isSingleLine = isSingleLine
        self.onCommit = onCommit
        self._isFocused = isFocused
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.textColor = textColor
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 5, bottom: 8, right: 5)
        tv.textContainer.lineFragmentPadding = 0
        // Scrolling stays on in both modes. With scrolling off, a
        // UITextView grows to fit its content and SwiftUI gives it
        // the whole composer area, which is how the room's box blew
        // up to half the screen. With scrolling on, the view stays
        // at its intrinsic one-line height; a long single line
        // scrolls horizontally instead of growing.
        tv.isScrollEnabled = true
        // Single-line mode (the room) is one line, no wrapping:
        // Return sends, and a pasted newline is clipped, not a
        // second line.
        if isSingleLine {
            tv.textContainer.maximumNumberOfLines = 1
            tv.textContainer.lineBreakMode = .byTruncatingTail
        }
        tv.returnKeyType = isSingleLine ? .send : .default
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .sentences
        context.coordinator.textView = tv
        // The placeholder is a label inside the text view, shown
        // only while the text is empty.
        let label = UILabel()
        label.text = placeholder
        label.font = font
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: tv.trailingAnchor, constant: -5),
        ])
        context.coordinator.placeholderLabel = label
        label.isHidden = !text.isEmpty
        let coordinator = context.coordinator
        tv.attributedText = Self.attributedString(
            for: text,
            font: font,
            textColor: textColor,
            onImageLoaded: { coordinator.refresh() }
        )
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        uiView.font = font
        uiView.textColor = textColor
        uiView.isScrollEnabled = true
        if isSingleLine {
            uiView.textContainer.maximumNumberOfLines = 1
            uiView.textContainer.lineBreakMode = .byTruncatingTail
        } else {
            uiView.textContainer.maximumNumberOfLines = 0
        }
        uiView.returnKeyType = isSingleLine ? .send : .default
        // Focus: the parent drives it (autofocus on appear). Only
        // call becomeFirstResponder when the parent asks and the
        // view is not already first responder, so a rebuild does
        // not steal focus mid-typing.
        if isFocused && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFocused && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
        // Only rebuild when the binding changed from outside the
        // text view (a sticker was tapped in the tray). While the
        // user is typing, textViewDidChange already pushed the new
        // text into the binding, so the two agree and rebuilding
        // would reset the cursor for nothing.
        let currentPlain = Self.plainText(from: uiView.attributedText)
        if currentPlain != text {
            let coordinator = context.coordinator
            coordinator.settingTextProgrammatically = true
            uiView.attributedText = Self.attributedString(
                for: text,
                font: font,
                textColor: textColor,
                onImageLoaded: { coordinator.refresh() }
            )
            coordinator.settingTextProgrammatically = false
            // A tray tap appends at the end, so the cursor goes
            // after the new emoji. The cursor is in the attributed
            // string's coordinates: each emoji is one attachment
            // character, so the plain text (with its 12-char
            // shortcodes) is longer than the attributed string.
            // Using the plain length here put the cursor past the
            // end of the text and crashed the app on the second
            // emoji. The end of the attributed string is the end
            // of the draft.
            uiView.selectedRange = NSRange(location: uiView.attributedText.length, length: 0)
            context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        }
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: WYSIWYGEditor
        weak var textView: UITextView?
        weak var placeholderLabel: UILabel?
        /// True while the coordinator itself is setting the text
        /// view's attributed string (a rebuild from the binding).
        /// textViewDidChange fires for a programmatic set too, and
        /// without this guard it reads the new string back and
        /// overwrites the binding, which is how a tray tap ate the
        /// typed text: the rebuild set the string, the delegate read
        /// it back, and the binding came out empty.
        var settingTextProgrammatically = false

        init(parent: WYSIWYGEditor) {
            self.parent = parent
        }

        /// Rebuild the display from the current binding text, keeping
        /// the cursor where it was. Used when an emoji image finishes
        /// loading.
        func refresh() {
            guard let tv = textView else { return }
            let cursor = tv.selectedRange
            settingTextProgrammatically = true
            tv.attributedText = WYSIWYGEditor.attributedString(
                for: parent.text,
                font: parent.font,
                textColor: parent.textColor,
                onImageLoaded: { [weak self] in self?.refresh() }
            )
            settingTextProgrammatically = false
            // Clamp the cursor: the text may have shortened if an
            // attachment replaced a longer delimiter.
            let maxLocation = tv.attributedText.length
            let location = min(cursor.location, maxLocation)
            tv.selectedRange = NSRange(location: location, length: 0)
            placeholderLabel?.isHidden = !parent.text.isEmpty
        }

        func textViewDidChange(_ textView: UITextView) {
            // A programmatic set is the view catching up to the
            // binding, not the user typing. Ignore it, or it reads
            // the rebuilt string back and clobbers the binding.
            guard !settingTextProgrammatically else { return }
            let plain = WYSIWYGEditor.plainText(from: textView.attributedText)
            // A rebuild can fire this delegate a beat after the flag
            // clears, while the view is still catching up. If the
            // attributed string still has content but the plain-text
            // read came back empty, the read is transient, not the
            // user deleting everything — do not clobber the draft
            // with it, or the emojis just added vanish and the field
            // goes blank.
            if plain.isEmpty && !parent.text.isEmpty && textView.attributedText.length > 0 {
                return
            }
            if plain != parent.text {
                parent.text = plain
            }
            placeholderLabel?.isHidden = !parent.text.isEmpty
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Single-line mode: Return sends the message instead of
            // inserting a newline.
            if parent.isSingleLine && text == "\n" {
                parent.onCommit?()
                return false
            }
            return true
        }
    }

    // MARK: - Conversion

    /// The plain text behind a displayed attributed string: an emoji
    /// attachment becomes its shortcode again, everything else is
    /// its literal text. This is what gets posted. The shortcode is
    /// read from the attribute on the attachment character, not from
    /// the attachment object, because the text view's copy drops an
    /// attachment subclass. The attribute alone is not enough: text
    /// typed right after an emoji can inherit the attribute, so the
    /// shortcode is only read when the character is also an
    /// attachment, which typed text never is.
    static func plainText(from attributed: NSAttributedString) -> String {
        var out = ""
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let shortcode = attrs[emojiShortcodeAttributeKey] as? String,
               attrs[.attachment] != nil {
                out += shortcode
            } else if attrs[.attachment] != nil {
                // An attachment with no shortcode (an image that is
                // not an emoji) has no plain-text form, so it
                // contributes nothing to the posted text.
            } else {
                out += attributed.attributedSubstring(from: range).string
            }
        }
        return out
    }

    /// Build the displayed attributed string from plain text: every
    /// shortcode that resolves to a known emoji becomes an inline
    /// image attachment at line height. A shortcode whose image has
    /// not loaded yet stays as its delimiter text, and the fetch is
    /// kicked off; when it lands, onImageLoaded rebuilds the view.
    static func attributedString(
        for plain: String,
        font: UIFont,
        textColor: UIColor,
        onImageLoaded: @escaping () -> Void
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        guard let regex = try? NSRegularExpression(pattern: wysiwygShortcodePattern) else {
            out.append(NSAttributedString(string: plain, attributes: baseAttrs))
            return out
        }
        let nsPlain = plain as NSString
        let matches = regex.matches(in: plain, range: NSRange(location: 0, length: nsPlain.length))
        var cursor = 0
        for match in matches {
            let range = match.range
            // The plain text before this shortcode.
            if range.location > cursor {
                let chunk = nsPlain.substring(with: NSRange(location: cursor, length: range.location - cursor))
                out.append(NSAttributedString(string: chunk, attributes: baseAttrs))
            }
            let shortcode = nsPlain.substring(with: range)
            let packID = nsPlain.substring(with: match.range(at: 1)).lowercased()
            let emojiID = nsPlain.substring(with: match.range(at: 2)).lowercased()
            if let url = StickerStore.shared.stickerURL(packID: packID, stickerID: emojiID) {
                if let image = SharedEmojiImageCache.shared.image(for: url) {
                    // The image, sized to the line height so it sits
                    // in the sentence like a character. The shortcode
                    // rides as an attribute on the attachment
                    // character, so it survives the text view's copy
                    // of the string.
                    let attachment = NSTextAttachment()
                    attachment.image = resizedForLine(image, lineHeight: font.lineHeight)
                    // Align the picture to the text baseline: the
                    // attachment's bounds are in the line's coordinate
                    // space, so a negative y drops it onto the baseline.
                    let height = font.lineHeight
                    let width = attachment.image.map { $0.size.width * height / max($0.size.height, 1) } ?? height
                    attachment.bounds = CGRect(x: 0, y: font.descender, width: width, height: height)
                    let attachmentString = NSMutableAttributedString(attachment: attachment)
                    attachmentString.addAttribute(emojiShortcodeAttributeKey, value: shortcode, range: NSRange(location: 0, length: attachmentString.length))
                    out.append(attachmentString)
                } else {
                    // Not loaded yet: show the delimiter for now and
                    // fetch in the background. When it lands, the
                    // view rebuilds and the picture appears.
                    out.append(NSAttributedString(string: shortcode, attributes: baseAttrs))
                    fetchImage(url: url, onImageLoaded: onImageLoaded)
                }
            } else {
                // Unknown pack or emoji: leave the delimiter as text.
                out.append(NSAttributedString(string: shortcode, attributes: baseAttrs))
            }
            cursor = range.location + range.length
        }
        if cursor < nsPlain.length {
            let chunk = nsPlain.substring(from: cursor)
            out.append(NSAttributedString(string: chunk, attributes: baseAttrs))
        }
        return out
    }

    /// Scale an emoji image down to the line height, keeping its
    /// aspect ratio. Small images are left alone, never upscaled.
    private static func resizedForLine(_ image: UIImage, lineHeight: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = lineHeight / size.height
        guard scale < 1 else { return image }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Fetch an emoji image in the background. A URL already in
    /// flight is not refetched. When the image lands it goes into
    /// the shared cache and onImageLoaded rebuilds the view.
    private static func fetchImage(url: URL, onImageLoaded: @escaping () -> Void) {
        guard SharedEmojiImageCache.shared.beginFetch(url) else { return }
        Task {
            defer { SharedEmojiImageCache.shared.endFetch(url) }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data)
            else { return }
            SharedEmojiImageCache.shared.set(image, for: url)
            await MainActor.run { onImageLoaded() }
        }
    }
}
