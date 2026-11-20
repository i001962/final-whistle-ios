import SwiftUI
import UIKit
import WebKit

// MARK: - Model

/// One episode from the Final Whistle YouTube channel
/// (Split & Peel, https://www.youtube.com/@split-peel).
/// No API key: the list comes from YouTube's public channel RSS feed,
/// which needs only the channel ID.
struct YouTubeVideo: Identifiable, Equatable {
    let id: String          // yt:videoId
    let title: String
    let published: Date?
    let thumbnailURL: URL?
    // Named `summary`, not `description`: a stored `description` in
    // the NSObject-based RSS parser below would try to override
    // NSObject's own `description` and the build fails on it.
    let summary: String?

    /// The shareable deep link: opens in the YouTube app when tapped
    /// elsewhere, and is what the share sheet hands out.
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    var embedURL: URL { URL(string: "https://www.youtube.com/embed/\(id)")! }
}

// MARK: - Service

enum YouTubeService {
    static let channelID = "UCQn56wvJDa4ukd5n8XF5z_A"
    static let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")!

    static func fetch() async throws -> [YouTubeVideo] {
        let (data, response) = try await URLSession.shared.data(from: feedURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return parse(data: data)
    }

    /// Parses the Atom feed. Pure and synchronous, so the unit test can
    /// feed it a fixed XML string. Element names are matched qualified
    /// (media:thumbnail, yt:videoId) with namespace processing off.
    static func parse(data: Data) -> [YouTubeVideo] {
        let parser = XMLParser(data: data)
        let delegate = RSSDelegate()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
        return delegate.videos
    }

    private final class RSSDelegate: NSObject, XMLParserDelegate {
        var videos: [YouTubeVideo] = []
        private var inEntry = false
        private var currentElement = ""
        private var text = ""
        private var videoID = ""
        private var title = ""
        private var published: Date?
        private var thumbnailURL: URL?
        // NOT `description`: this class inherits from NSObject, and a
        // stored property called `description` would override NSObject's
        // own `description` — "Cannot override with a stored property
        // 'description'".
        private var summaryText = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            if elementName == "entry" {
                inEntry = true
                videoID = ""; title = ""; published = nil
                thumbnailURL = nil; summaryText = ""
            }
            guard inEntry else { return }
            switch elementName {
            case "title", "yt:videoId", "published", "media:description":
                currentElement = elementName
                text = ""
            case "media:thumbnail":
                if thumbnailURL == nil, let url = attributeDict["url"] {
                    thumbnailURL = URL(string: url)
                }
            default:
                currentElement = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inEntry, !currentElement.isEmpty else { return }
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            guard inEntry else { return }
            switch elementName {
            case "title": title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "yt:videoId": videoID = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "published":
                published = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "media:description": summaryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "entry":
                if !videoID.isEmpty {
                    videos.append(YouTubeVideo(
                        id: videoID, title: title, published: published,
                        thumbnailURL: thumbnailURL,
                        summary: summaryText.isEmpty ? nil : summaryText
                    ))
                }
                inEntry = false
            default: break
            }
            currentElement = ""
        }
    }
}

// MARK: - List

/// The episodes tab: the channel's videos as 16:9 cards in the app
/// theme. Tapping a card opens the player sheet; sharing lives there.
struct VideosView: View {
    @State private var videos: [YouTubeVideo] = []
    @State private var loading = false
    @State private var failed: String?
    @State private var playing: YouTubeVideo?

    var body: some View {
        Group {
            if loading, videos.isEmpty {
                ProgressView("Loading episodes…")
                    .tint(Color.fwLime)
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failed, videos.isEmpty {
                ContentUnavailableView(
                    "Episodes did not load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(failed)
                )
                .foregroundStyle(Color.fwMuted)
            } else if videos.isEmpty {
                ContentUnavailableView(
                    "No episodes yet",
                    systemImage: "play.rectangle.on.rectangle",
                    description: Text("Nothing on the Final Whistle channel right now.")
                )
                .foregroundStyle(Color.fwMuted)
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(videos) { video in
                            VideoCard(video: video) { playing = video }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .refreshable { await load(force: true) }
            }
        }
        .background(Color.fwBackground)
        .toolbarBackground(Color.fwBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await load(force: false) }
        .sheet(item: $playing) { video in
            VideoPlayerSheet(video: video)
                .presentationDetents([.large])
        }
    }

    private func load(force: Bool) async {
        if !force, !videos.isEmpty { return }
        loading = true
        failed = nil
        do {
            videos = try await YouTubeService.fetch()
        } catch {
            failed = error.localizedDescription
        }
        loading = false
    }
}

private struct VideoCard: View {
    let video: YouTubeVideo
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    AsyncImage(url: video.thumbnailURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.fwPanelSoft
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()

                    // Play button, centered on the thumbnail.
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.fwAccent, in: Circle())
                        .shadow(radius: 6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fwLine, lineWidth: 1))

                Text(video.title)
                    .font(.headline)
                    .foregroundStyle(Color.fwText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text("Final Whistle")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwAccentSoft)
                    Text("·")
                        .foregroundStyle(Color.fwMuted)
                    if let published = video.published {
                        Text(published, style: .relative)
                            .font(.subheadline)
                            .foregroundStyle(Color.fwMuted)
                    }
                }
            }
            .padding(12)
            .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fwLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(video.title)")
    }
}

// MARK: - Player

/// The episode player: YouTube's own iframe player in a WKWebView, so
/// fans get the real thing — scrub, fullscreen, picture-in-picture,
/// speed, captions — not a half-built custom player. Below it, the
/// title, description, and the share row: the native share sheet plus
/// a one-tap copy of the watch link for social distribution.
struct VideoPlayerSheet: View {
    let video: YouTubeVideo
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    YouTubePlayerView(video: video)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))

                    Text(video.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.fwText)

                    if let published = video.published {
                        Text("Final Whistle · \(published.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                            .foregroundStyle(Color.fwMuted)
                    }

                    if let summary = video.summary {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Color.fwMuted)
                            .lineLimit(6)
                    }

                    HStack(spacing: 12) {
                        ShareLink(item: video.watchURL,
                                  subject: Text(video.title),
                                  message: Text(video.title)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.fwAccent)

                        Button {
                            UIPasteboard.general.string = video.watchURL.absoluteString
                            copied = true
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                copied = false
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link")
                        }
                        .buttonStyle(.bordered)
                        .tint(Color.fwMuted)
                    }
                }
                .padding()
            }
            .background(Color.fwBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// WKWebView wrapper for the YouTube iframe embed. Inline playback,
/// autoplay on open, picture-in-picture and fullscreen all on.
private struct YouTubePlayerView: UIViewRepresentable {
    let video: YouTubeVideo

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url == nil else { return }
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(video.id)?playsinline=1&rel=0&autoplay=1"
        allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; fullscreen"
        allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
