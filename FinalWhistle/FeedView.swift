import SwiftUI

/// The whole app is one list: the /football channel on Hypersnap.
/// No tabs, no trending. Styled on final-whistle.app: near-black navy
/// background, panel cards with a thin line border, lime highlights,
/// magenta for the compose button.
///
/// The feed is the channel under its real parent URL
/// (Quilcast's feed/parent_urls), so it is the same channel posts go
/// into — fresh casts daily, not the stale feed/channels bucket.
/// Tapping a cast opens its thread; the heart fills when you liked it
/// (viewer state from the node, Quilcast's mine/taps pattern); the
/// repost button opens a quoted repost, never a plain recast.
struct FeedView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var showingCompose = false
    @State private var replyingTo: Cast?
    @State private var quoting: Cast?
    @State private var notice: String?

    // /football channel image, from the channel list at
    // hypersnap-stats.qstorage.quilibrium.com/all-channels-formatted.json
    // (id "football", 25,587 followers, 1,143 members, public casting).
    private static let channelImageURL = URL(string: "https://imagedelivery.net/BXluQx4ige9GuW0Ia56BHw/e457005e-e084-4e2e-288b-d94160184700/original")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AsyncImage(url: Self.channelImageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.fwPanelSoft
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Football channel")
                        .font(.caption)
                        .fontWeight(.bold)
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.fwAccentSoft)
                    Text("Casts posted into /football on Hypersnap.")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwMuted)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            switch feed.state {
            case .loading where feed.casts.isEmpty:
                ProgressView("Loading the feed…")
                    .tint(Color.fwLime)
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No casts yet",
                    systemImage: "sportscourt",
                    description: Text("Nothing in the /football channel right now. Pull to refresh.")
                )
                .foregroundStyle(Color.fwMuted)
            case .failed(let message):
                ContentUnavailableView(
                    "The feed did not load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
                .foregroundStyle(Color.fwMuted)
            default:
                // ScrollView, not List: a NavigationLink in a List draws
                // a disclosure chevron on every card. In a ScrollView it
                // does not, and the link is the native iOS pattern for
                // opening a thread. The previous onTapGesture on the row
                // was swallowed by the List and tapping a cast did
                // nothing, so threads were unreachable. Buttons inside
                // the label still act as buttons; taps anywhere else
                // follow the link.
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(feed.casts) { cast in
                            NavigationLink(value: cast) {
                                CastRow(
                                    cast: cast,
                                    onReply: { replyingTo = cast },
                                    onQuote: { quoting = cast },
                                    onReacted: { notice = $0 }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
                .refreshable { await feed.refresh(viewerFID: identity.record?.fid) }
            }

            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Color.fwMuted)
                    .padding(.vertical, 4)
            }
        }
        .background(Color.fwBackground)
        .toolbarBackground(Color.fwBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            if identity.isSignedIn {
                Button {
                    showingCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(Color.fwAccent, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .accessibilityLabel("New post")
                .padding()
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(onPosted: { Task { await feed.refresh(viewerFID: identity.record?.fid) } })
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $replyingTo) { cast in
            ComposeView(parent: cast, onPosted: { Task { await feed.refresh(viewerFID: identity.record?.fid) } })
                .presentationDetents([.large])
        }
        .sheet(item: $quoting) { cast in
            ComposeView(quoted: cast, onPosted: {
                feed.markQuoted(cast)
                Task { await feed.refresh(viewerFID: identity.record?.fid) }
            })
            .presentationDetents([.large])
        }
        .task { await feed.refresh(viewerFID: identity.record?.fid) }
        .onChange(of: identity.record?.fid.value) {
            Task { await feed.refresh(viewerFID: identity.record?.fid) }
        }
        .navigationDestination(for: Cast.self) { cast in
            ThreadView(cast: cast)
        }
    }
}

struct CastRow: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    let cast: Cast
    let onReply: () -> Void
    let onQuote: () -> Void
    let onReacted: (String) -> Void
    @State private var working = false

    private var liked: Bool { feed.isLiked(cast) }
    private var quoted: Bool { feed.isQuoted(cast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: cast.author.pfpURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.fwPanelSoft
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(cast.author.displayTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.fwText)
                            .lineLimit(1)
                        Text("@\(cast.author.displayUsername)")
                            .font(.subheadline)
                            .foregroundStyle(Color.fwMuted)
                            .lineLimit(1)
                    }
                    Text(cast.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                }
            }

            Text(cast.text)
                .font(.body)
                .foregroundStyle(Color.fwText)

            if let quotedRef = cast.embeds?.first(where: { $0.castID != nil })?.castID {
                QuotedCastView(ref: quotedRef)
            }

            if cast.replies.count > 0 {
                HStack(spacing: 4) {
                    Text("View \(cast.replies.count) \(cast.replies.count == 1 ? "reply" : "replies")")
                    Image(systemName: "chevron.right")
                }
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color.fwAccentSoft)
            }

            HStack(spacing: 24) {
                Button(action: onReply) {
                    Label("\(cast.replies.count)", systemImage: "bubble.left")
                }
                .disabled(!identity.isSignedIn)
                Button(action: onQuote) {
                    Label("\(cast.reactions.recastsCount)", systemImage: "quote.bubble")
                        .foregroundStyle(quoted ? Color.fwLime : Color.fwMuted)
                }
                .disabled(!identity.isSignedIn)
                .accessibilityLabel(quoted ? "Quoted repost" : "Quote repost")
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label("\(feed.likesCount(for: cast))", systemImage: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Color.red : Color.fwMuted)
                }
                .disabled(!identity.isSignedIn || working)
                .accessibilityLabel(liked ? "Unlike" : "Like")
            }
            .font(.subheadline)
            .foregroundStyle(Color.fwMuted)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding()
        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.fwLine, lineWidth: 1)
        )
    }

    /// Optimistic toggle, Quilcast-style: the heart fills and the count
    /// moves at once; the node call follows, and a failure reverts it.
    /// The old version only bumped the count after a successful call and
    /// kept no liked state at all, so a tap that landed on the node
    /// still showed an empty heart and an unchanged count.
    private func toggleLike() async {
        let shouldLike = feed.toggleLike(cast)
        working = true
        defer { working = false }
        do {
            _ = try await identity.react(to: cast, type: 1, remove: !shouldLike)
        } catch {
            feed.setLiked(cast, liked: !shouldLike)
            onReacted("Like failed: \(error.localizedDescription)")
        }
    }
}

/// A quoted cast embedded in a cast: the quoted author's name and text,
/// fetched by hash. Tapping it opens that cast's thread.
struct QuotedCastView: View {
    let ref: CastEmbed.CastIDRef
    @State private var quoted: Cast?
    @State private var failed = false

    var body: some View {
        Group {
            if let quoted {
                NavigationLink(value: quoted) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@\(quoted.author.displayUsername)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.fwText)
                        Text(quoted.text)
                            .font(.subheadline)
                            .foregroundStyle(Color.fwMuted)
                            .lineLimit(4)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.fwLine, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if failed {
                Text("Quoted cast unavailable")
                    .font(.footnote)
                    .foregroundStyle(Color.fwMuted)
            }
        }
        .task {
            do {
                quoted = try await FeedService.userCast(hash: ref.hash)
            } catch {
                failed = true
            }
        }
    }
}
