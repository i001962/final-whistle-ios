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
    @State private var selectedQuoted: Cast?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            // No header here any more: the channel icon lives in the
            // top bar next to the account picture (ContentView), and the
            // "Football channel / posted into /football on Hypersnap"
            // text is gone — the feed itself says where you are.
            //
            // The ScrollView is always present, with .refreshable on it.
            // It used to live inside the switch's default case, so
            // pulling to refresh set state = .loading, the switch
            // re-evaluated, and the ScrollView was recreated — the pull
            // gesture never fired, and the feed only refreshed when
            // navigating away and back (which re-ran .task). Now the
            // ScrollView has a stable identity and the state only
            // changes what is inside it.
            ScrollView {
                switch feed.state {
                case .loading where feed.casts.isEmpty:
                    ProgressView("Loading the feed…")
                        .tint(Color.fwLime)
                        .foregroundStyle(Color.fwMuted)
                        .frame(maxWidth: .infinity, minHeight: 400)
                case .empty:
                    ContentUnavailableView(
                        "No casts yet",
                        systemImage: "sportscourt",
                        description: Text("Nothing in the /football channel right now. Pull to refresh.")
                    )
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, minHeight: 400)
                case .failed(let message):
                    ContentUnavailableView(
                        "The feed did not load",
                        systemImage: "wifi.exclamationmark",
                        description: Text(message)
                    )
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, minHeight: 400)
                default:
                    // ScrollView, not List: a NavigationLink in a List draws
                    // a disclosure chevron on every card. In a ScrollView it
                    // does not, and the link is the native iOS pattern for
                    // opening a thread. The previous onTapGesture on the row
                    // was swallowed by the List and tapping a cast did
                    // nothing, so threads were unreachable. Buttons inside
                    // the label still act as buttons; taps anywhere else
                    // follow the link.
                    LazyVStack(spacing: 10) {
                        ForEach(feed.casts) { cast in
                            NavigationLink(value: cast) {
                                CastRow(
                                    cast: cast,
                                    onReply: { replyingTo = cast },
                                    onQuote: { quoting = cast },
                                    onOpenQuote: { selectedQuoted = $0 },
                                    onReacted: { notice = $0 }
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                }
            }
            .refreshable { await feed.refresh(viewerFID: identity.record?.fid) }

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
        .navigationDestination(item: $selectedQuoted) { cast in
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
    /// Opens a quoted cast's thread. Nil renders the quoted card without
    /// a tap target.
    let onOpenQuote: ((Cast) -> Void)?
    let onReacted: (String) -> Void
    @State private var working = false

    init(cast: Cast, onReply: @escaping () -> Void, onQuote: @escaping () -> Void,
         onOpenQuote: ((Cast) -> Void)? = nil, onReacted: @escaping (String) -> Void) {
        self.cast = cast
        self.onReply = onReply
        self.onQuote = onQuote
        self.onOpenQuote = onOpenQuote
        self.onReacted = onReacted
    }

    private var liked: Bool { feed.isLiked(cast) }
    private var quoted: Bool { feed.isQuoted(cast) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                CachedImage(url: cast.author.pfpURL)
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

            CastTextView(cast: cast)

            CastEmbedsView(cast: cast, onOpenQuote: onOpenQuote)

            // No "View N replies" hint: the whole card is already a link
            // to the thread, and the reply button below carries the
            // count. The hint was redundant visual noise.
            HStack(spacing: 24) {
                Button(action: onReply) {
                    Label("\(cast.replies.count)", systemImage: "bubble.left")
                }
                .disabled(!identity.isSignedIn)
                Button(action: onQuote) {
                    // Circular arrows, not a speech bubble: the reply
                    // button already is one, and the two looked alike.
                    // This is a repost, and the count is the recast count.
                    Label("\(cast.reactions.recastsCount)", systemImage: "arrow.2.squarepath")
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
        // Full width, or the stack centers the card: a LazyVStack
        // defaults to center alignment, so a card only as wide as its
        // content — a one-word post like "Test", no embeds — sat
        // centered and read as indented, even though it is a
        // top-level cast. Same lesson as the room rows: the width
        // belongs inside the row.
        .frame(maxWidth: .infinity, alignment: .leading)
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
