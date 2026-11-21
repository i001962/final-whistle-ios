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

    /// A URL is a sticker when it is in one of the packs, or when it
    /// matches the hosted-pack shape (Quilcast's stickerPack check).
    func isSticker(_ url: URL) -> Bool {
        let string = url.absoluteString
        if packs.flatMap(\.stickers).contains(where: { $0.url == string }) {
            return true
        }
        return string.range(
            of: #"^https://final-whistle\.app/st/[\w-]{8}/[0-9a-f]{24}\.webp$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Add an image URL to "My stickers". Returns false when the URL
    /// is not a usable image link or is already in a pack.
    @discardableResult
    func addSticker(url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.scheme == "https",
              CastMedia.isImageURL(parsed),
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
}

/// A sticker as it is, with no frame (Quilcast's ui.tsx Sticker):
/// the image at its natural shape, capped at 160pt, transparency kept.
struct StickerView: View {
    let url: URL

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
        .frame(maxWidth: 160, maxHeight: 160, alignment: .leading)
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

    private var allStickers: [Sticker] { store.packs.flatMap(\.stickers) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if allStickers.isEmpty {
                    Text("No stickers yet. Paste an image URL below to add one — any picture works as a sticker.")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwMuted)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                            ForEach(allStickers, id: \.url) { sticker in
                                Button {
                                    onPick(sticker.url)
                                    dismiss()
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

                HStack(spacing: 8) {
                    TextField("Paste an image URL", text: $urlField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 12))
                    Button("Add") { addURL() }
                        .foregroundStyle(Color.fwAccent)
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
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func addURL() {
        let raw = urlField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              url.scheme == "https",
              CastMedia.isImageURL(url)
        else {
            urlError = "That needs to be a full https:// image link."
            return
        }
        if store.addSticker(url: raw) {
            urlField = ""
            urlError = nil
        } else {
            urlError = "That sticker is already in the pack."
        }
    }
}
