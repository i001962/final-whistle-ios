import SwiftUI

// MARK: - Live match rooms

/// A match room is a thread, not a channel and not a parent URL:
/// the room's messages are the replies under one root cast, read
/// through the conversation endpoint. The room itself is just that
/// anchor cast — no server-side room object exists yet, and the list
/// below is the whole directory for now (one room per match, later).
struct ChatRoom: Identifiable, Hashable {
    let id: String
    let title: String
    /// The cast hash this room is a thread under (40 hex chars, no
    /// 0x). Every message in the room is a reply to this cast, or a
    /// reply to one of those replies.
    let rootHash: String

    static let all: [ChatRoom] = [
        ChatRoom(
            id: "gantry",
            title: "The Gantry",
            rootHash: "ef1449dcf2b8642c19c15c8ea16b33b826655855"
        ),
    ]
}

/// The rooms directory: one row per room.
struct RoomsView: View {
    var body: some View {
        List {
            ForEach(ChatRoom.all) { room in
                // Value-based: the room is part of the router
                // path, so clearing the path pops back to this
                // directory. A destination-based link can leave
                // the room on screen with an empty path.
                NavigationLink(value: room) {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.title3)
                            .foregroundStyle(Color.fwAccent)
                            .frame(width: 40, height: 40)
                            .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 10))
                        Text(room.title)
                            .font(.headline)
                            .foregroundStyle(Color.fwText)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
        .navigationDestination(for: ChatRoom.self) { room in
            RoomView(room: room)
        }
    }
}

// MARK: - One room: IRC-style chat

/// A room as a group chat: an IRC-style feed, newest at the bottom,
/// pinned there — the latest message is always visible and older ones
/// scroll off the top. Replies are NOT hidden in a thread — every
/// reply shows inline in the feed, iMessage-style, with a small quote
/// of the message it answers above it. Every message in the room is
/// a reply with parent_cast_id (a real Farcaster reply, so other
/// clients still see the thread): a plain message answers the room's
/// root cast, a reply answers the message it was long-pressed on.
/// The room loads the root cast's conversation and flattens the whole
/// tree into the one list.
///
/// The pinning is a flipped list, not a scroll-to-bottom call: the
/// messages are newest-first and the ScrollView is rotated 180°, with
/// each row rotated back, so the list is anchored at the bottom by
/// construction and a new message just appears there. A scrollTo call
/// on a lazy stack can miss on first load (rows not laid out yet) and
/// fights the user's scroll position on every poll.
struct RoomView: View {
    let room: ChatRoom

    @EnvironmentObject private var identity: IdentityStore
    /// The sticker store, observed so the tray re-renders whenever
    /// a pack or sticker changes. Without this the tray reads
    /// StickerStore.shared once and stays stale: after a sticker
    @State private var messages: [Cast] = []
    @State private var rootCast: Cast?
    @State private var loading = false
    @State private var failed: String?
    @State private var draft = ""
    @State private var replyingTo: Cast?
    @State private var sending = false
    @State private var sendError: String?
    @State private var showingProfile = false
    /// The sticker tray above the text box. Tapping a sticker adds
    /// its shortcode to the draft; nothing posts until the user hits
    /// send. The draft text is the only record of the chosen
    /// emojis — they show inline in the editor, nowhere else, and
    /// backspace deletes one. The embeds are derived from the
    /// shortcodes in the text when sending, so there is no second
    /// list to keep in sync.
    @State private var showStickerTray = false
    @State private var likedHashes: Set<String> = []
    @State private var composerFocused = false
    /// The composer's measured content height, reported by the
    /// editor as the draft grows. The field starts at one line (44)
    /// and grows to show the whole draft, up to about five lines,
    /// then the text scrolls inside it.
    @State private var composerHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if loading, messages.isEmpty {
                ProgressView("Loading room…")
                    .tint(Color.fwLime)
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failed, messages.isEmpty {
                ContentUnavailableView(
                    "Room did not load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(failed)
                )
                .foregroundStyle(Color.fwMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Be the first to say something about the match.")
                )
                .foregroundStyle(Color.fwMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { cast in
                            RoomMessageRow(
                                cast: cast,
                                parent: parentOf(cast),
                                liked: isLiked(cast),
                                onLike: { Task { await toggleLike(cast) } },
                                onReply: {
                                    replyingTo = cast
                                    composerFocused = true
                                }
                            )
                            // Each row turns back upright inside the
                            // flipped list; the first row in the data
                            // (newest) sits at the visual bottom.
                            .rotationEffect(.degrees(180))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .rotationEffect(.degrees(180))
            }

            composer
        }
        .background(Color.fwBackground)
        // No system nav bar here: the room is pushed onto the stack,
        // and without this the system back chevron shows as a second
        // header under the app's own top bar. Back comes from that
        // top bar (upper left); swipe-back still works.
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await load()
            // Live room: poll for other fans' messages while open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await load()
            }
        }
        .sheet(isPresented: $showingProfile) {
            ProfileView()
        }
    }

    private func load() async {
        loading = true
        failed = nil
        do {
            // The room IS the thread under its root cast: one
            // conversation fetch returns the root plus its whole reply
            // tree, flattened in, so replies show inline instead of
            // hiding in threads. No parent_urls fan-out any more.
            let thread = try await FeedService.conversation(hash: room.rootHash, viewerFID: identity.record?.fid)
            rootCast = thread
            var all = [thread]
            all += Self.flatten(thread.directReplies ?? [])
            let deduped = FeedService.dedup(all)
            // Newest-first: the flipped list shows the first row at
            // the visual bottom, so the latest message is the one
            // pinned there.
            messages = deduped.sorted { $0.timestamp > $1.timestamp }
            likedHashes = Set(deduped.filter { $0.viewerContext?.liked == true }.map { $0.hash.lowercased() })
        } catch {
            failed = error.localizedDescription
        }
        loading = false
    }

    /// Walk a conversation's nested direct_replies into one flat list.
    /// nonisolated: it is pure (touches no view state), and load()
    /// calls it from inside a TaskGroup child task, which runs off
    /// the main actor — without this the build fails with
    /// "Main actor-isolated static method 'flatten' cannot be called
    /// from outside of the actor".
    private nonisolated static func flatten(_ replies: [Cast]) -> [Cast] {
        var out: [Cast] = []
        for reply in replies {
            out.append(reply)
            out += flatten(reply.directReplies ?? [])
        }
        return out
    }

    /// The message this one answers, for its inline quote. Found by
    /// parent hash; a top-level message has no parent.
    private func parentOf(_ cast: Cast) -> Cast? {
        guard let parentHash = cast.parentHash else { return nil }
        let key = parentHash.replacingOccurrences(of: "0x", with: "").lowercased()
        // A reply to the room's root cast carries no quote: the root
        // IS the room, so quoting it on every plain message just
        // restates the topic and tells the user they are replying to
        // a cast they never chose to answer. Only replies to other
        // messages get the small quote.
        if key == room.rootHash.lowercased() { return nil }
        return messages.first { $0.hash.lowercased() == key }
    }

    private func isLiked(_ cast: Cast) -> Bool { likedHashes.contains(cast.hash.lowercased()) }

    private func toggleLike(_ cast: Cast) async {
        guard identity.isSignedIn else { showingProfile = true; return }
        let key = cast.hash.lowercased()
        let liking = !likedHashes.contains(key)
        if liking { likedHashes.insert(key) } else { likedHashes.remove(key) }
        do {
            _ = try await identity.react(to: cast, type: 1, remove: !liking)
        } catch {
            // Revert the optimistic tap; the node never saw it.
            if liking { likedHashes.remove(key) } else { likedHashes.insert(key) }
        }
    }

    /// The composer: a reply chip when answering a message, then the
    /// sticker tray when open, then the text field and send. Sending
    /// while signed out opens the account sheet instead of failing.
    /// Tapping a sticker adds its shortcode to the draft; it shows
    /// inline in the editor as its picture, and nothing posts until
    /// send.
    private var composer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack {
                    Text("Replying to @\(replyingTo.author.username ?? "fid:\(replyingTo.author.fid.value)")")
                        .font(.subheadline)
                        .foregroundStyle(Color.fwAccentSoft)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.fwMuted)
                    }
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.fwPanelSoft)
            }

            if showStickerTray {
                StickerTrayView { url in addStickerToDraft(url: url) }
                    .layoutPriority(1)
            }

            // The composer is a Liquid Glass capsule (Glazier pattern
            // 4, Chat): height U at rest, corners U / 2, growing into
            // a card while typing. The glass is the background — the
            // editor's own solid panel and stroke are gone, and the
            // text view underneath is clear — so the capsule floats
            // over the messages instead of sitting on a flat bar.
            HStack(spacing: 10) {
                Button {
                    showStickerTray.toggle()
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title2)
                        .foregroundStyle(showStickerTray ? Color.fwAccent : Color.fwMuted)
                }
                .accessibilityLabel("Stickers")

                // The editor shows the emoji itself, not the
                // delimiter: a tapped emoji sits in the sentence as
                // its picture (WYSIWYG). Return sends the message.
                // The field grows with the draft: one line to start,
                // up to about five lines, so a long message is never
                // truncated to "..." while typing. Past that the text
                // scrolls inside the field.
                WYSIWYGEditor(
                    text: $draft,
                    placeholder: "Message the room…",
                    font: .preferredFont(forTextStyle: .body),
                    textColor: .label,
                    sendOnReturn: true,
                    onCommit: { Task { await send() } },
                    isFocused: $composerFocused,
                    contentHeight: $composerHeight
                )
                .frame(height: min(max(composerHeight, 44), 150))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending ? Color.fwMuted : Color.fwAccent)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: GlassMetrics.composerU / 2, style: .continuous))

            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(Color.fwAccentSoft)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Add a sticker to the draft being written: its shortcode goes
    /// into the text, and the editor shows it inline as its picture.
    /// Nothing posts until the user hits send. A sticker already in
    /// the draft is not added twice, and a cast holds at most 2
    /// embeds, so the third tap is ignored. To remove one, the user
    /// backspaces it out of the editor; the embeds are derived from
    /// the text at send time, so a deleted emoji is not sent.
    private func addStickerToDraft(url: String) {
        guard let shortcode = StickerStore.shared.shortcode(for: url) else { return }
        guard !draft.contains(shortcode),
              StickerStore.shared.stickerURLs(forShortcodesIn: draft).count < 2
        else { return }
        StickerStore.shared.recordUse(url: url)
        if draft.isEmpty {
            draft = shortcode + " "
        } else if draft.hasSuffix(" ") || draft.hasSuffix("\n") {
            draft += shortcode + " "
        } else {
            draft += " " + shortcode + " "
        }
    }

    private func send() async {
        guard identity.isSignedIn else { showingProfile = true; return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        // Every message in the room is a reply: a plain message
        // answers the room's root cast, a long-press reply answers
        // that message. If the root has not loaded yet there is
        // nothing to answer, so wait rather than posting nowhere.
        guard let target = replyingTo ?? rootCast else {
            sendError = "The room hasn't loaded yet — try again in a moment."
            return
        }
        sending = true
        sendError = nil
        // Take the reply target out of state FIRST: if this send fails,
        // the next message must still answer the root cast. Clearing
        // only after a successful reply let a failed send leave reply
        // mode stuck on, so every later post came out as a reply to
        // the same message. The default is always the root cast; a
        // reply to a message is one explicit long-press per message.
        replyingTo = nil
        // The emoji travel as embeds with the text, as ordinary
        // image URLs (the colleague's sticker transport): they are
        // derived from the shortcodes in the draft, so an emoji the
        // user backspaced out of the editor is not sent. The cast
        // carries the image URL on-chain, so every client renders the
        // picture, and the URL is the authority for what the emoji
        // means — a shortcode that resolves to a different URL than
        // the embed is not rendered inline, so the meaning cannot be
        // hijacked by a changed pack. The shortcode in the text is
        // the legible label, verified against the embed URL by the
        // inline pipeline. The send path just puts the URL string in
        // Embed field 1. (The earlier emoji:// experiment put a short
        // identifier in the embed instead; new sends use the URL, and
        // the emoji:// read path in CastMedia stays for those casts.)
        let embeds = Array(StickerStore.shared.stickerURLs(forShortcodesIn: text).prefix(2))
        do {
            let hash = try await identity.reply(to: target, text: text, linkURLs: embeds)
            draft = ""
            composerFocused = false
            await reloadUntilVisible(hash: hash)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    /// The node takes a moment to index a new cast into the root
    /// cast's conversation — the reload right after submit usually
    /// returns before it lands, so the message looks lost even though
    /// it posted fine. Poll until the new hash shows up.
    private func reloadUntilVisible(hash: String, attempts: Int = 5) async {
        let key = hash.replacingOccurrences(of: "0x", with: "").lowercased()
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await load()
            if messages.contains(where: { $0.hash.lowercased() == key }) { return }
        }
    }
}

/// One message in the room: pfp, username, time, text with mentions
/// put back, then its embeds (a sticker bare, a photo framed). Reply
/// and like live on a long press, not on the row. A reply carries a
/// small quote of the message it answers above its own text,
/// iMessage-style — nothing hides behind a "replies" link.
private struct RoomMessageRow: View {
    let cast: Cast
    /// The message this one answers, if it is a reply.
    let parent: Cast?
    let liked: Bool
    let onLike: () -> Void
    let onReply: () -> Void

    /// A stable color per author, so a name reads as who it is at a
    /// glance (IRC nick colors). The FID hashes to one of six bright
    /// colors that all read on the dark background.
    private static func colorForFID(_ fid: UInt64) -> Color {
        let palette: [Color] = [
            Color(hex: "ff6b9d"),
            Color(hex: "fea282"),
            Color(hex: "a2e634"),
            Color(hex: "7dd3fc"),
            Color(hex: "c4b5fd"),
            Color(hex: "fde047"),
        ]
        return palette[Int(fid % UInt64(palette.count))]
    }

    /// The author's name for the inline line: the username, not the
    /// display name (a display name can say anything, the username
    /// is who it is).
    private var authorName: String {
        cast.author.username ?? "fid:\(cast.author.fid.value)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let pfpURL = cast.author.pfpURL {
                CachedImage(url: pfpURL)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.fwMuted)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 3) {
                // The message this answers, as one small line: a name
                // and a snippet, no card, no extra indent. The old
                // version was a padded two-line card that pushed the
                // quote right of the message and made a top-level post
                // landing after a reply read like part of its thread.
                if let parent {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.fwAccent)
                            .frame(width: 2)
                        Text("@\(parent.author.username ?? "fid:\(parent.author.fid.value)"): \(parent.text)")
                            .font(.caption)
                            .foregroundStyle(Color.fwMuted)
                            .lineLimit(1)
                    }
                }

                // The name and the message share one flowing line:
                // the name in the author's color leads, the message
                // follows and wraps under it. No separate header, no
                // timestamp here — the time is disclosed on long press.
                CastTextView(
                    cast: cast,
                    authorName: authorName,
                    authorColor: Self.colorForFID(cast.author.fid.value)
                )
                .font(.subheadline)
                .foregroundStyle(Color.fwText)

                // Embeds: a sticker draws bare, a photo framed
                // (CastEmbedsView splits them). A sticker-only message
                // has no text, so this is the whole message. Stickers
                // are 48pt here — half the feed's 96pt cap — because
                // a chat line wants a thumbnail, not a poster.
                CastEmbedsView(cast: cast, onOpenQuote: nil, stickerSize: 48)
            }
        }
        // Full width — and it has to be HERE, inside the row, not on
        // the row from outside. The list is flipped 180°, so a row's
        // visual left edge is W - width: a row only as wide as its
        // text sits further right the shorter the message is, a
        // progressive indent that reads as a nested reply. A frame
        // put on the row from the ForEach only widens an invisible
        // wrapper around the rotated row; the visible content stays
        // narrow and stays shifted. The row's own width must be full
        // for the double rotation to land it on the left edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        // Reply, like, and the time live on a long press, not on the
        // row: the row is just who said it and what they said. The
        // time is disclosed here, with the actions, instead of
        // taking a line on every message.
        .contextMenu {
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button(action: onLike) {
                Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
            }
            // The time, as an informational row: the full date and
            // time, not the relative "37 min" the feed shows.
            Text(cast.timestamp, style: .date)
                + Text(" ")
                + Text(cast.timestamp, style: .time)
        }
    }
}
