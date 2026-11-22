import LinkPresentation
import SwiftUI

// MARK: - Embed media (Quilcast shared.ts isImg/isVid/sized, ui.tsx Embeds)

/// Embed classification and sizing, ported from Quilcast's shared.ts.
/// An embed is an image by extension, or by host (Farcaster's image CDN
/// and Imgur serve images at extension-less URLs); a video by extension.
/// Farcaster's image CDN resizes on request, so the feed loads a w=1200
/// variant instead of the full original.
enum CastMedia {
    static func isImageURL(_ url: URL) -> Bool {
        let string = url.absoluteString
        if string.range(of: #"\.(png|jpe?g|gif|webp|avif)(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return url.host == "imagedelivery.net" || url.host == "i.imgur.com"
    }

    static func isVideoURL(_ url: URL) -> Bool {
        url.absoluteString.range(of: #"\.(m3u8|mp4|webm|mov)(\?|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// imagedelivery.net/<account>/<id>/original -> /<variant>.
    static func sizedImageURL(_ url: URL, variant: String = "w=1200") -> URL {
        guard url.host == "imagedelivery.net" else { return url }
        let string = url.absoluteString
        guard string.hasSuffix("/original") else { return url }
        return URL(string: String(string.dropLast("/original".count)) + "/\(variant)") ?? url
    }
}

extension Cast {
    /// The embed URLs worth rendering (Quilcast urlsOf). An embed is
    /// never dropped just because its URL is also in the text: the text
    /// shows a truncated orange link, not the picture or the preview
    /// card, so dropping the embed leaves the cast with only the link
    /// text and no image at all. That was the Chelsea-logo post — the
    /// .png was in the embeds AND in the text, the dedup dropped it,
    /// and nothing rendered. The composer strips an embedded URL out
    /// of the text on new posts, so the duplication the dedup was
    /// guarding against does not happen there either.
    var embedURLs: [URL] {
        guard let embeds else { return [] }
        return embeds.compactMap { embed -> URL? in
            guard let raw = embed.url, let url = URL(string: raw) else { return nil }
            return url
        }
    }

    var imageEmbedURLs: [URL] { embedURLs.filter(CastMedia.isImageURL) }
    var videoEmbedURLs: [URL] { embedURLs.filter(CastMedia.isVideoURL) }
    var linkEmbedURLs: [URL] { embedURLs.filter { !CastMedia.isImageURL($0) && !CastMedia.isVideoURL($0) } }
    var quotedCasts: [CastEmbed.CastIDRef] { embeds?.compactMap(\.castID) ?? [] }
}

// MARK: - Embeds block

/// A cast's embeds, Quilcast's Embeds layout: pictures (and videos) side
/// by side in a horizontal strip when there are several, a lone picture
/// full width; link cards full width below; quoted casts full width.
/// Lives inside the cast card, under the text.
struct CastEmbedsView: View {
    let cast: Cast
    /// Opens a quoted cast's thread. Passed down from the card's owner
    /// (FeedView / ThreadView), which presents it via
    /// navigationDestination(item:) — a quoted card must NOT be a
    /// NavigationLink itself (see QuotedCastView).
    let onOpenQuote: ((Cast) -> Void)?
    /// The sticker cap. The feed uses the default 96pt; the rooms pass
    /// 48pt so a sticker reads as a thumbnail in a chat line.
    var stickerSize: CGFloat = 96
    @State private var fullscreenImage: FullscreenImageItem?

    /// Sticker embeds render bare (see StickerView); the rest of the
    /// pictures keep the framed photo layout.
    private var stickers: [URL] { cast.imageEmbedURLs.filter(StickerStore.shared.isSticker) }
    private var images: [URL] { cast.imageEmbedURLs.filter { !StickerStore.shared.isSticker($0) } }
    private var videos: [URL] { cast.videoEmbedURLs }
    private var links: [URL] { cast.linkEmbedURLs }
    private var quotes: [CastEmbed.CastIDRef] { cast.quotedCasts }

    var body: some View {
        Group {
            ForEach(stickers, id: \.self) { url in
                StickerView(url: url, maxSize: stickerSize)
            }

            if images.count + videos.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(images, id: \.self) { url in
                            EmbedImageTile(url: url, onTap: { fullscreenImage = FullscreenImageItem(url: $0) })
                        }
                        ForEach(videos, id: \.self) { url in
                            EmbedVideoTile(url: url)
                                .frame(width: 240, height: 180)
                        }
                    }
                }
            } else if let url = images.first {
                EmbedImageView(url: url, onTap: { fullscreenImage = FullscreenImageItem(url: $0) })
            } else if let url = videos.first {
                EmbedVideoTile(url: url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
            }

            ForEach(links, id: \.self) { url in
                LinkPreviewView(url: url)
            }

            ForEach(quotes, id: \.self) { ref in
                QuotedCastView(ref: ref, onOpen: onOpenQuote)
            }
        }
        .fullScreenCover(item: $fullscreenImage) { item in
            FullScreenImageView(url: item.url)
        }
    }
}

private struct FullscreenImageItem: Identifiable {
    var id: URL { url }
    let url: URL
}

// MARK: - Images

/// One image embed, full width, at most 480pt tall (Quilcast caps a lone
/// picture at 510px). Loads the w=1200 CDN variant, not the original.
/// Tapping opens the full-resolution image.
struct EmbedImageView: View {
    let url: URL
    let onTap: (URL) -> Void

    var body: some View {
        Button { onTap(url) } label: {
            AsyncImage(url: CastMedia.sizedImageURL(url)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    ZStack {
                        Color.fwPanelSoft
                        Image(systemName: "photo")
                            .foregroundStyle(Color.fwMuted)
                    }
                    .frame(height: 160)
                case .empty:
                    ZStack {
                        Color.fwPanelSoft
                        ProgressView().tint(Color.fwLime)
                    }
                    .frame(height: 200)
                @unknown default:
                    Color.fwPanelSoft.frame(height: 200)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: 480)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
        .accessibilityLabel("Image")
    }
}

/// One image inside a multi-media strip: a fixed tile, cropped to fill.
private struct EmbedImageTile: View {
    let url: URL
    let onTap: (URL) -> Void

    var body: some View {
        Button { onTap(url) } label: {
            AsyncImage(url: CastMedia.sizedImageURL(url, variant: "w=600")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    ZStack {
                        Color.fwPanelSoft
                        Image(systemName: "photo").foregroundStyle(Color.fwMuted)
                    }
                case .empty:
                    ZStack {
                        Color.fwPanelSoft
                        ProgressView().tint(Color.fwLime)
                    }
                @unknown default:
                    Color.fwPanelSoft
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 240, height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
        .accessibilityLabel("Image")
    }
}

/// A video embed: no inline player yet (the node gives no poster or
/// size), so a tile with a play button that opens the video in Safari.
/// Quilcast plays inline; this is the v1 stand-in, noted in the file.
private struct EmbedVideoTile: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            ZStack {
                Color.fwPanelSoft
                VStack(spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(Color.fwText)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                        .lineLimit(1)
                }
                .padding()
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
        .accessibilityLabel("Video, \(url.host ?? "link")")
    }
}

// MARK: - Full-screen image viewer

/// Tap an image to see it full screen: pinch to zoom, drag while zoomed,
/// tap anywhere (or the X) to close. Quilcast's image viewer is a swipeable
/// gallery; this is one image at a time for v1.
struct FullScreenImageView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var anchorScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var anchorOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.6))
                case .empty:
                    ProgressView().tint(.white)
                @unknown default:
                    ProgressView().tint(.white)
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, min(4, anchorScale * $0)) }
                    .onEnded { _ in
                        anchorScale = scale
                        if scale == 1 { offset = .zero; anchorOffset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: anchorOffset.width + value.translation.width,
                            height: anchorOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in anchorOffset = offset }
            )
            .onTapGesture { dismiss() }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding()
                    .accessibilityLabel("Close image")
                }
                Spacer()
            }
        }
    }
}

// MARK: - Link previews

/// A link card (Quilcast's LinkCard, iOS-native via LinkPresentation):
/// the page's OpenGraph title, image and domain, fetched on-device.
/// Falls back to a plain link row when the metadata fetch fails, so a
/// card never sits empty. Metadata is cached in memory per URL so
/// scrolling a row off and back does not refetch.
struct LinkPreviewView: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?
    @State private var failed = false

    var body: some View {
        Group {
            if let metadata {
                // No fixed height: the card sizes itself to the link.
                // A YouTube video wants a tall card (thumbnail + title)
                // and a plain article wants a short one; forcing both
                // to 110pt let the video card overflow its frame and
                // draw on top of the action row and the next cast.
                // sizeThatFits in the representable measures it.
                LPLinkViewRepresentable(metadata: metadata)
            } else if failed {
                Link(destination: url) {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(Color.fwAccentSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.host ?? url.absoluteString)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.fwText)
                                .lineLimit(1)
                            Text(url.absoluteString)
                                .font(.caption)
                                .foregroundStyle(Color.fwMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    ProgressView().tint(Color.fwLime)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .padding(.horizontal, 12)
            }
        }
        .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
        .task { await load() }
    }

    private func load() async {
        if let cached = LinkMetadataCache.shared.metadata(for: url) {
            metadata = cached
            return
        }
        do {
            let fetched = try await LPMetadataProvider().startFetchingMetadata(for: url)
            LinkMetadataCache.shared.store(fetched, for: url)
            metadata = fetched
        } catch {
            failed = true
        }
    }
}

@MainActor
private final class LinkMetadataCache {
    static let shared = LinkMetadataCache()
    private var store: [URL: LPLinkMetadata] = [:]

    func metadata(for url: URL) -> LPLinkMetadata? { store[url] }
    func store(_ metadata: LPLinkMetadata, for url: URL) { store[url] = metadata }
}

private struct LPLinkViewRepresentable: UIViewRepresentable {
    let metadata: LPLinkMetadata

    func makeUIView(context: Context) -> LPLinkView {
        LPLinkView(metadata: metadata)
    }

    func updateUIView(_ view: LPLinkView, context: Context) {
        view.metadata = metadata
    }

    /// Ask the link view how tall it wants to be for this width, so
    /// SwiftUI gives it that height instead of a fixed one. A video
    /// link is tall (thumbnail + title); an article link is short.
    /// Without this the view overflowed its frame and overlapped the
    /// action row and the next cast.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        guard fitting.height > 0 else { return nil }
        return CGSize(width: width, height: fitting.height)
    }
}

// MARK: - Quoted casts

/// A quoted cast embedded in a cast: the quoted author's name and text,
/// fetched by hash, plus its first image if it has one. Tapping it opens
/// that cast's thread via onOpen. Mentions inside the quoted text are
/// tappable too (same AttributedString links as the feed).
///
/// This must NOT be a NavigationLink: it lives inside the card, and the
/// card itself is already a NavigationLink to its own thread. A nested
/// link is the reason quote reposts once rendered with no quoted cast
/// at all — the inner link swallowed the preview — so a quote looked
/// like a standalone post with no reference to what it quoted.
struct QuotedCastView: View {
    let ref: CastEmbed.CastIDRef
    let onOpen: ((Cast) -> Void)?
    @State private var quoted: Cast?
    @State private var failed = false
    @State private var retryCount = 0

    var body: some View {
        Group {
            if let quoted {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AsyncImage(url: quoted.author.pfpURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.fwPanelSoft
                        }
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                        Text("@\(quoted.author.displayUsername)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.fwText)
                    }
                    CastTextView(cast: quoted, font: .subheadline, textColor: .fwMuted)
                        .lineLimit(4)
                    if let imageURL = quoted.imageEmbedURLs.first {
                        AsyncImage(url: CastMedia.sizedImageURL(imageURL, variant: "w=600")) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure, .empty:
                                Color.fwPanelSoft
                            @unknown default:
                                Color.fwPanelSoft
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    if let onOpen { onOpen(quoted) }
                }
            } else if failed {
                Button("Quoted cast did not load — tap to retry") {
                    failed = false
                    retryCount += 1
                }
                .font(.footnote)
                .foregroundStyle(Color.fwAccentSoft)
            } else {
                ProgressView()
                    .tint(Color.fwMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: retryCount) {
            do {
                quoted = try await FeedService.userCast(hash: ref.hash)
            } catch {
                failed = true
            }
        }
    }
}
