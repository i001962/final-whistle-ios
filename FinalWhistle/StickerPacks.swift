import SwiftUI

// MARK: - Stickers (Quilcast's stickers.tsx + server/stickers.mjs, Telegram-style packs)
//
// Quilcast's pattern, ported to Final Whistle:
//   - A sticker is an ordinary picture embed in a cast (a URL in the
//     cast's embeds) that every Farcaster client shows as a picture;
//     this client draws it as a sticker: bare, no frame, transparency
//     kept (PNG/WebP stay as they are).
//   - Stickers live in packs. A pack is a list of sticker URLs, each
//     with a short label. Quilcast's packs live on its server, one per
//     account, signed with the Farcaster key; this app's packs live on
//     device (LocalStore) until a hosted pack service exists.
//   - A hosted pack's sticker URL follows the same shape as Quilcast's
//     (quilcast.com/st/<pack>/<hash>.webp):
//     final-whistle.app/st/<pack>/<hash>.webp. Any URL at that shape
//     renders as a sticker even if it is not in a local pack, so a
//     hosted pack works without an app update.
//   - "My stickers" is the pack the user fills by pasting image URLs.
//     Additional packs are just more StickerPack entries.

struct Sticker: Codable, Hashable {
    let url: String
    let label: String
    /// How often the user has sent this sticker, and when they last
    /// did. A pack file without these fields decodes with the
    /// defaults, so the hosted manifest (which has neither) reads
    /// fine.
    var useCount: Int = 0
    var lastUsedAt: Date? = nil

    /// The hosted manifest calls the sticker's name `id`; the
    /// property stays `label` (every call site uses it), and this
    /// mapping is what the synthesized Codable reads and writes.
    /// No custom init: a custom init(from:) with extra CodingKeys
    /// cases breaks the synthesized encode(to:), which is the
    /// "does not conform to Encodable" error Xcode showed.
    enum CodingKeys: String, CodingKey {
        case url
        case label = "id"
        case useCount, lastUsedAt
    }

    init(url: String, label: String, useCount: Int = 0, lastUsedAt: Date? = nil) {
        self.url = url
        self.label = label
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}

struct StickerPack: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    var stickers: [Sticker]

    /// The hosted manifest calls the pack's display name `name`;
    /// the property stays `title`, and this mapping is what the
    /// synthesized Codable reads and writes. The manifest's other
    /// top-level fields (format, version, description, author) and
    /// each sticker's extra fields (alt, mimeType, width, height,
    /// sha256, tags) are ignored by the decoder. No custom init:
    /// same Encodable breakage as Sticker (see there).
    enum CodingKeys: String, CodingKey {
        case id
        case title = "name"
        case stickers
    }

    init(id: String, title: String, stickers: [Sticker]) {
        self.id = id
        self.title = title
        self.stickers = stickers
    }
}

final class StickerStore: ObservableObject {
    /// Swift 6: a static shared instance of a non-Sendable
    /// ObservableObject is a compile error without this. The store is
    /// only ever touched from the main actor (SwiftUI views and the
    /// picker), so the opt-out is safe; it is not accessed from
    /// background tasks.
    nonisolated(unsafe) static let shared = StickerStore()

    @Published private(set) var packs: [StickerPack] = []

    private let store = LocalStore<[StickerPack]>(fileName: "sticker-packs.json")

    private init() {
        packs = (try? store.load()) ?? [StickerPack(id: "mine", title: "My stickers", stickers: [])]
    }

    /// The hosted-pack URL for a sticker, mirroring Quilcast's
    /// stickerUrl: final-whistle.app/st/<pack>/<hash>.webp.
    static func hostedStickerURL(pack: String, hash: String) -> String {
        "https://final-whistle.app/st/\(pack)/\(hash).webp"
    }

    // MARK: - Built-in packs (data, shipped with the app)

    /// Packs that ship with the app, not entered by the user. Each
    /// pack is a JSON file in the app bundle (banny-pack.json), so
    /// the pack is data, not code: the pack id, title, sticker names
    /// and image URLs live in the file, and adding a sticker is
    /// editing the file, not a source change. The same file is the
    /// shape a hosted pack would be fetched as later — the phone
    /// book the emoji:// resolver reads. If a bundled file fails to
    /// load, the hardcoded copy below is the fallback, so the pack
    /// never disappears from a bundling mistake.
    static let builtInPacks: [StickerPack] = {
        var packs: [StickerPack] = []
        if let url = Bundle.main.url(forResource: "banny-pack", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let pack = try? JSONDecoder().decode(StickerPack.self, from: data) {
            packs.append(pack)
        }
        if packs.isEmpty {
            packs = [
                StickerPack(id: "banny", title: "Banny", stickers: [
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/goal.webp", label: "goal"),
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/lfg.webp", label: "lfg"),
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/popcorn.webp", label: "popcorn"),
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/redcard.webp", label: "redcard"),
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/stoned.webp", label: "stoned"),
                    Sticker(url: "https://qstorage.quilibrium.com/storage-castrater/banny-pack/wow.webp", label: "wow"),
                ]),
            ]
        }
        return packs
    }()

    /// All packs the app knows: the user's own plus the built-ins.
    /// Rendering and shortcode resolution look here, so a built-in
    /// sticker works for a reader who never added the pack.
    /// Every pack the app knows: the user's own packs, plus the
    /// built-in packs. A pack that the user has already adopted (its
    /// id is in their packs) is listed once, from their copy — the
    /// built-in copy is not also shown, or Banny appears twice in
    /// the tray once the first sticker is sent.
    var allKnownPacks: [StickerPack] {
        let userIDs = Set(packs.map(\.id))
        return packs + Self.builtInPacks.filter { !userIDs.contains($0.id) }
    }

    /// Resolve an inline shortcode `:packid:emojiconid:` to its image
    /// URL, or nil when the pack or the sticker is unknown. The label
    /// is the sticker id inside its pack.
    func stickerURL(packID: String, stickerID: String) -> URL? {
        let packID = packID.lowercased()
        let stickerID = stickerID.lowercased()
        for pack in allKnownPacks where pack.id.lowercased() == packID {
            if let sticker = pack.stickers.first(where: { $0.label.lowercased() == stickerID }),
               let url = URL(string: sticker.url) {
                return url
            }
        }
        return nil
    }

    /// The shortcode for a sticker URL, e.g. `:banny:goal:`, or nil
    /// when the URL is in no known pack. The sender puts this in the
    /// cast text and attaches the image as an ordinary embed; the
    /// reader resolves it back to the same URL.
    func shortcode(for url: String) -> String? {
        for pack in allKnownPacks {
            if let sticker = pack.stickers.first(where: { $0.url == url }) {
                return ":\(pack.id):\(sticker.label):"
            }
        }
        return nil
    }

    /// The image URLs for the inline emoji shortcodes in a piece of
    /// text, in order, deduplicated. The text is the single source of
    /// truth: a sticker is attached exactly when its shortcode is in
    /// the text, so deleting the emoji from the editor (backspace)
    /// un-attaches it, and there is no second list to keep in sync.
    /// The caller caps the count to the embed budget.
    func stickerURLs(forShortcodesIn text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #":([a-z0-9_][a-z0-9_-]{0,31}):([a-z0-9_][a-z0-9_-]{0,31}):"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen: Set<String> = []
        var out: [String] = []
        for match in matches {
            let packID = nsText.substring(with: match.range(at: 1)).lowercased()
            let emojiID = nsText.substring(with: match.range(at: 2)).lowercased()
            guard let url = stickerURL(packID: packID, stickerID: emojiID) else { continue }
            let urlString = url.absoluteString
            guard !seen.contains(urlString) else { continue }
            seen.insert(urlString)
            out.append(urlString)
        }
        return out
    }

    // MARK: - emoji:// URIs (room experiment, 2026-11-23)

    /// The emoji:// URI for a sticker: `emoji://<pack>/<name>`, e.g.
    /// `emoji://banny/goal`. It is an identifier, not a location: it
    /// names the pack and the sticker inside it, and the app resolves
    /// it through its sticker catalog to the image URL. It is short
    /// (17 bytes here, against ~70 for the https URL), it survives
    /// the files moving to a new host (only the catalog entry
    /// changes), and its two parts are exactly the shortcode's two
    /// parts, so the text and the embed match trivially. It goes in
    /// Embed field 1 as a plain string; the FIP's rule 11 only
    /// requires 1–256 bytes of UTF-8, with no scheme restriction.
    static func emojiURI(packID: String, stickerID: String) -> String {
        "emoji://\(packID.lowercased())/\(stickerID.lowercased())"
    }

    /// True when a string is an emoji:// URI (scheme `emoji`, not
    /// https). Such a string is never a link to open — it is an
    /// identifier to resolve, or to fall back from.
    static func isEmojiURI(_ string: String) -> Bool {
        string.lowercased().hasPrefix("emoji://")
    }

    /// Resolve an emoji:// URI to its image URL through the sticker
    /// catalog, or nil when the pack or the sticker is unknown to
    /// this app. A nil means the reader does not have that pack, so
    /// the shortcode in the text stays literal text instead of
    /// rendering as an image — the fallback is the shortcode, never
    /// a broken image or a link card.
    func resolveEmojiURI(_ uri: String) -> URL? {
        guard Self.isEmojiURI(uri),
              let url = URL(string: uri),
              url.scheme?.lowercased() == "emoji",
              let packID = url.host?.lowercased(),
              !packID.isEmpty else { return nil }
        // The name is the path after the leading slash, without any
        // trailing slash or query. `emoji://banny/goal` has path
        // "/goal"; `emoji://banny/goal.webp` would not match a
        // sticker id, so the extension is stripped if present.
        var name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let dot = name.lastIndex(of: ".") {
            name = String(name[..<dot])
        }
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return stickerURL(packID: packID, stickerID: name)
    }

    /// The emoji:// URIs for the inline emoji shortcodes in a piece
    /// of text, in order, deduplicated — the parallel of
    /// stickerURLs(forShortcodesIn:), but as identifiers instead of
    /// image URLs. The room sends these as the embeds: the cast
    /// carries the short identifier on-chain, and the reader
    /// resolves it to the image through their catalog.
    func stickerEmojiURIs(forShortcodesIn text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #":([a-z0-9_][a-z0-9_-]{0,31}):([a-z0-9_][a-z0-9_-]{0,31}):"#) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen: Set<String> = []
        var out: [String] = []
        for match in matches {
            let packID = nsText.substring(with: match.range(at: 1)).lowercased()
            let emojiID = nsText.substring(with: match.range(at: 2)).lowercased()
            guard stickerURL(packID: packID, stickerID: emojiID) != nil else { continue }
            let uri = Self.emojiURI(packID: packID, stickerID: emojiID)
            guard !seen.contains(uri) else { continue }
            seen.insert(uri)
            out.append(uri)
        }
        return out
    }

    /// Copy a built-in pack into the user's packs, so it shows in the
    /// picker and can be managed. Returns false when the pack is
    /// already added or unknown.
    @discardableResult
    func addPack(id: String) -> Bool {
        guard let pack = Self.builtInPacks.first(where: { $0.id == id }),
              !packs.contains(where: { $0.id == id })
        else { return false }
        packs.append(pack)
        try? store.save(packs)
        return true
    }

    /// Make sure the pack containing a sticker is in the user's
    /// packs, so a tap on a built-in sticker records its use. A
    /// built-in pack joins the user's packs the first time one of
    /// its stickers is sent.
    func ensurePack(for url: String) {
        for pack in Self.builtInPacks where pack.stickers.contains(where: { $0.url == url }) {
            _ = addPack(id: pack.id)
            return
        }
    }

    /// A URL is a sticker when it is in one of the packs (the user's
    /// or a built-in), or when it matches the hosted-pack shape
    /// (Quilcast's stickerPack check).
    func isSticker(_ url: URL) -> Bool {
        let string = url.absoluteString
        if allKnownPacks.flatMap(\.stickers).contains(where: { $0.url == string }) {
            return true
        }
        return string.range(
            of: #"^https://final-whistle\.app/st/[\w-]{8}/[0-9a-f]{24}\.webp$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Add an image URL to "My stickers" with an explicit name, the
    /// id the shortcode uses (`:mine:<label>:`). The label is the
    /// emoji's name, so it must fit the shortcode charset: a letter,
    /// digit or underscore first, then up to 31 letters, digits,
    /// underscores or dashes. Returns false when the URL is not an
    /// https link, the name is not a valid shortcode id, or the URL
    /// is already in a pack. It deliberately does NOT check the
    /// address for an image extension: the caller proves the link is
    /// an image by content type before calling here, and an image
    /// served at an extension-less URL (a Castrater public file, an
    /// image CDN) is a valid sticker.
    @discardableResult
    func addSticker(url: String, label: String) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = URL(string: url),
              parsed.scheme == "https",
              !label.isEmpty,
              label.range(of: #"^[a-z0-9_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
              !packs.flatMap(\.stickers).contains(where: { $0.url == url }),
              !packs.flatMap(\.stickers).contains(where: { $0.label.lowercased() == label })
        else { return false }
        if packs.isEmpty {
            packs = [StickerPack(id: "mine", title: "My stickers", stickers: [])]
        }
        packs[0].stickers.append(Sticker(url: url, label: label))
        try? store.save(packs)
        return true
    }

    /// Add an image URL to "My stickers". Returns false when the URL
    /// is not an https link or is already in a pack. It deliberately
    /// does NOT check the address for an image extension: the picker
    /// proves the link is an image by content type before calling
    /// here, and an image served at an extension-less URL (a Castrater
    /// public file, an image CDN) is a valid sticker.
    @discardableResult
    func addSticker(url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.scheme == "https",
              !packs.flatMap(\.stickers).contains(where: { $0.url == url })
        else { return false }
        if packs.isEmpty {
            packs = [StickerPack(id: "mine", title: "My stickers", stickers: [])]
        }
        let label = parsed.deletingPathExtension().lastPathComponent
        packs[0].stickers.append(Sticker(url: url, label: label.isEmpty ? "Sticker" : label))
        try? store.save(packs)
        return true
    }

    /// True when the URL serves an image, by content type. HEAD first
    /// (no body); some hosts don't answer HEAD, so a ranged GET is
    /// the fallback. A page URL comes back as text/html and fails.
    /// Shared by the sticker picker and the add-emoji sheet.
    static func urlIsImage(_ url: URL) async -> Bool {
        var head = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse,
           let mime = http.mimeType, mime.hasPrefix("image/") {
            return true
        }
        var get = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: get),
              let http = response as? HTTPURLResponse,
              let mime = http.mimeType, mime.hasPrefix("image/") else { return false }
        return true
    }

    /// Record that a sticker was sent. The picker calls this when a
    /// sticker is tapped, so the counts track what the user actually
    /// reaches for, not what they added. A built-in pack joins the
    /// user's packs first, so its stickers can carry a use count.
    func recordUse(url: String) {
        ensurePack(for: url)
        for packIndex in packs.indices {
            if let stickerIndex = packs[packIndex].stickers.firstIndex(where: { $0.url == url }) {
                packs[packIndex].stickers[stickerIndex].useCount += 1
                packs[packIndex].stickers[stickerIndex].lastUsedAt = Date()
                try? store.save(packs)
                return
            }
        }
    }

    /// Remove a sticker from every pack that has it.
    func removeSticker(url: String) {
        for packIndex in packs.indices {
            packs[packIndex].stickers.removeAll { $0.url == url }
        }
        try? store.save(packs)
    }

    /// Reorder "My stickers" (the pack the user curates). Called by
    /// the Manage screen's List onMove.
    func moveSticker(fromOffsets: IndexSet, toOffset: Int) {
        guard !packs.isEmpty else { return }
        packs[0].stickers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try? store.save(packs)
    }

    /// Reorder "My stickers" by what the user actually sends: most
    /// sent first, then most recently sent. Stickers never sent keep
    /// their added order at the end.
    func sortByMostUsed() {
        guard !packs.isEmpty else { return }
        packs[0].stickers.sort { a, b in
            if a.useCount != b.useCount { return a.useCount > b.useCount }
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
        try? store.save(packs)
    }
}

/// A sticker as it is, with no frame (Quilcast's ui.tsx Sticker):
/// the image at its natural shape, capped at 160pt, transparency kept.
struct StickerView: View {
    let url: URL
    /// The cap on the rendered size. The feed keeps the default 96pt
    /// (a sticker post is a standalone thing there); the rooms pass
    /// 48pt, thumbnail scale for a chat line.
    var maxSize: CGFloat = 96

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                Image(systemName: "photo")
                    .foregroundStyle(Color.fwMuted)
            case .empty:
                ProgressView().tint(Color.fwLime)
            @unknown default:
                EmptyView()
            }
        }
        // IRC-scale, not a poster: 96pt is a big emoji, visible
        // without taking over the chat. 160pt filled the viewport
        // height on a sticker-only message.
        .frame(maxWidth: maxSize, maxHeight: maxSize, alignment: .leading)
    }
}

/// The composer's sticker picker: a grid of the packs' stickers, tap
/// to send; plus a paste-an-image-URL row to grow "My stickers".
/// (Quilcast's StickerPicker: a tab per pack; this one is one pack
/// for now, more packs are more sections.)
struct StickerPickerSheet: View {
    @ObservedObject private var store = StickerStore.shared
    @Environment(\.dismiss) private var dismiss
    let onPick: (String) -> Void

    @State private var urlField = ""
    @State private var urlError: String?
    @State private var checking = false

    /// Every sticker the picker can send: the user's own packs plus
    /// the built-in packs, so Banny is just there, no install step.
    private var allStickers: [Sticker] { store.allKnownPacks.flatMap(\.stickers) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if allStickers.isEmpty {
                    // One sticker is one picture — not a Telegram pack,
                    // not a zip, just a direct link to an image file.
                    Text("No stickers yet. One sticker is one picture — paste a direct link to an image file (.png, .jpg, .webp or .gif) and it joins the pack.")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwMuted)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                            ForEach(allStickers, id: \.url) { sticker in
                                Button {
                                    // A built-in pack joins the user's
                                    // packs the first time one of its
                                    // stickers is sent, so the counts
                                    // track what the user actually
                                    // reaches for. The parent
                                    // (RoomView) closes the panel when
                                    // onPick fires, so the user lands
                                    // back on the chat feed while the
                                    // sticker sends.
                                    store.ensurePack(for: sticker.url)
                                    store.recordUse(url: sticker.url)
                                    onPick(sticker.url)
                                } label: {
                                    AsyncImage(url: URL(string: sticker.url)) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().scaledToFit()
                                        case .failure:
                                            Image(systemName: "photo")
                                                .foregroundStyle(Color.fwMuted)
                                        case .empty:
                                            ProgressView().tint(Color.fwLime)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                }
                                .accessibilityLabel(sticker.label)
                            }
                        }
                    }
                }

                NavigationLink {
                    ManageStickersView()
                } label: {
                    Label("Manage stickers", systemImage: "slider.horizontal.3")
                }

                HStack(spacing: 8) {
                    TextField("Paste a direct image link", text: $urlField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await addURL() } }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                    Button(checking ? "Checking…" : "Add") { Task { await addURL() } }
                        .foregroundStyle(Color.fwAccent)
                        .disabled(checking)
                }
                if let urlError {
                    Text(urlError)
                        .font(.caption)
                        .foregroundStyle(Color.fwAccentSoft)
                }
                Spacer()
            }
            .padding(16)
            .background(Color.fwBackground)
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
    }

    private func addURL() async {
        let raw = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "https" else {
            urlError = "That needs to be a full https:// link."
            return
        }
        // Fast path: a direct image link (extension or known image
        // host) needs no network check.
        if CastMedia.isImageURL(url) {
            finishAdd(raw)
            return
        }
        // Otherwise ask the link what it is. The old check only read
        // the address, so an image served at an extension-less URL —
        // a Castrater public file, an image CDN — was rejected even
        // though it is a perfectly good picture. The content type is
        // the proof, not the spelling of the URL.
        checking = true
        urlError = nil
        let isImage = await urlIsImage(url)
        checking = false
        if isImage {
            finishAdd(raw)
        } else {
            urlError = "That link isn't a picture. Paste a direct link to an image file — one ending in .png, .jpg, .webp or .gif — not a web page."
        }
    }

    private func finishAdd(_ raw: String) {
        if store.addSticker(url: raw) {
            urlField = ""
            urlError = nil
        } else {
            urlError = "That sticker is already in the pack."
        }
    }

    /// True when the URL serves an image, by content type. HEAD first
    /// (no body); some hosts don't answer HEAD, so a ranged GET is
    /// the fallback. A page URL comes back as text/html and fails.
    private func urlIsImage(_ url: URL) async -> Bool {
        await StickerStore.urlIsImage(url)
    }
}

/// Add your own emoji by URL: paste a direct image link and give
/// it a name, and it joins "My stickers" as `:mine:<name>:`.
/// The name is the shortcode id, so it must fit the shortcode
/// charset (letters, digits, underscores and dashes, starting with
/// a letter, digit or underscore). The image is proved by content
/// type, not by the spelling of the URL, so an extension-less image
/// link works. Once added, the emoji sits in the tray next to Banny
/// and taps in like any other inline emoji: the shortcode goes in
/// the text and the image travels as an embed, which is what the
/// reader resolves the shortcode against.
struct AddEmojiView: View {
    @ObservedObject private var store = StickerStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var urlField = ""
    @State private var nameField = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("One emoji is one picture — paste a direct link to an image file (.png, .jpg, .webp or .gif) and give it a name. It joins your stickers as :mine:your-name:.")
                    .font(.subheadline)
                    .foregroundStyle(Color.fwMuted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Image link")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwText)
                    TextField("https://…", text: $urlField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwText)
                    TextField("e.g. dance", text: $nameField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                    Text("Letters, numbers, _ and -, starting with a letter, number or _. This is the name you type between the colons.")
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                }
                Button(checking ? "Checking…" : "Add emoji") { Task { await add() } }
                    .foregroundStyle(Color.fwAccent)
                    .disabled(checking || urlField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.fwAccentSoft)
                }
                Spacer()
            }
            .padding(16)
            .background(Color.fwBackground)
            .navigationTitle("Add an emoji")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
    }

    private func add() async {
        let raw = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: raw), url.scheme == "https" else {
            error = "That needs to be a full https:// link."
            return
        }
        guard name.range(of: #"^[a-z0-9_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil else {
            error = "That name doesn't fit. Use letters, numbers, _ and -, starting with a letter, number or _."
            return
        }
        // Fast path: a direct image link (extension or known image
        // host) needs no network check.
        if !CastMedia.isImageURL(url) {
            checking = true
            error = nil
            let isImage = await StickerStore.urlIsImage(url)
            checking = false
            guard isImage else {
                error = "That link isn't a picture. Paste a direct link to an image file — one ending in .png, .jpg, .webp or .gif — not a web page."
                return
            }
        }
        if store.addSticker(url: raw, label: name) {
            dismiss()
        } else {
            error = "That link or name is already in your stickers."
        }
    }
}

/// Manage "My stickers": delete and reorder, and one tap to sort by
/// what the user actually sends most. Reached from the picker's
/// "Manage stickers" row. The order here is the order in the picker.
private struct ManageStickersView: View {
    @ObservedObject private var store = StickerStore.shared

    private var stickers: [Sticker] {
        store.packs.isEmpty ? [] : store.packs[0].stickers
    }

    var body: some View {
        List {
            Section {
                if stickers.isEmpty {
                    Text("No stickers yet.")
                        .foregroundStyle(Color.fwMuted)
                } else {
                    ForEach(stickers, id: \.url) { sticker in
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: sticker.url)) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFit()
                                case .failure:
                                    Image(systemName: "photo")
                                        .foregroundStyle(Color.fwMuted)
                                case .empty:
                                    ProgressView().tint(Color.fwLime)
                                @unknown default:
                                    EmptyView()
                                }
                            }
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sticker.label)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.fwText)
                                if sticker.useCount > 0 {
                                    Text("Sent \(sticker.useCount) time\(sticker.useCount == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(Color.fwMuted)
                                } else {
                                    Text("Not sent yet")
                                        .font(.caption)
                                        .foregroundStyle(Color.fwMuted)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let urls = offsets.map { stickers[$0].url }
                        for url in urls {
                            store.removeSticker(url: url)
                        }
                    }
                    .onMove { from, to in
                        store.moveSticker(fromOffsets: from, toOffset: to)
                    }
                }
            } header: {
                Text("My stickers")
            } footer: {
                Text("Drag to reorder. Swipe left to delete. The order here is the order in the picker.")
            }

            Section {
                Button("Sort by most used") {
                    store.sortByMostUsed()
                }
            } footer: {
                Text("Puts the stickers you send most at the top.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
        .navigationTitle("Manage stickers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }
}
