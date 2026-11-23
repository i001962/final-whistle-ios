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
    /// did. Old saved packs have neither field, so both default and
    /// the old JSON still decodes.
    var useCount: Int = 0
    var lastUsedAt: Date? = nil
}

struct StickerPack: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    var stickers: [Sticker]
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

    // MARK: - Built-in packs (static, shipped with the app)

    /// Packs that ship with the app, not entered by the user. The
    /// banny images are the d33m art, served straight from the
    /// footy-fc/d33m repo on GitHub (raw.githubusercontent.com) —
    /// the art already lives there publicly, so the pack works with
    /// no file upload and no VPS step. A sticker in a built-in pack
    /// renders as a sticker for everyone, even a reader who has not
    /// added the pack — the pack is the shared registry, the same
    /// shape as Slack's workspace emoji list.
    static let builtInPacks: [StickerPack] = [
        StickerPack(id: "banny", title: "Banny", stickers: [
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_goal.png", label: "goal"),
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_lfg.png", label: "lfg"),
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_popcorn.png", label: "popcorn"),
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_redcard.png", label: "redcard"),
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_stoned.png", label: "stoned"),
            Sticker(url: "https://raw.githubusercontent.com/footy-fc/d33m/main/public/assets/banny_wow.png", label: "wow"),
        ]),
    ]

    /// All packs the app knows: the user's own plus the built-ins.
    /// Rendering and shortcode resolution look here, so a built-in
    /// sticker works for a reader who never added the pack.
    var allKnownPacks: [StickerPack] { packs + Self.builtInPacks }

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
