import SwiftUI

// MARK: - Live match rooms

/// A match room is a parent URL fans post to, not a channel: the
/// room's messages are the casts carrying
/// `https://final-whistle.app/chat/<n>` as parent_url, read through
/// the same feed/parent_urls endpoint as /football. The room itself
/// is just an address — no server-side room object exists yet, and
/// the list below is the whole directory for now (one room per
/// match, later).
struct ChatRoom: Identifiable, Hashable {
    let id: String
    let title: String
    let parentURL: String

    static let all: [ChatRoom] = [
        ChatRoom(
            id: "gantry",
            title: "The Gantry",
            parentURL: "https://final-whistle.app/chat/gantry"
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
/// of the message it answers above it. A top-level message posts with
/// the room as parent_url; a reply posts with parent_cast_id (a real
/// Farcaster reply, so other clients still see the thread), and the
/// room loads each top-level cast's conversation and flattens the
/// whole tree into the one list.
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
    @State private var messages: [Cast] = []
    @State private var loading = false
    @State private var failed: String?
    @State private var draft = ""
    @State private var replyingTo: Cast?
    @State private var sending = false
    @State private var sendError: String?
    @State private var showingProfile = false
    @State private var showingStickers = false
    @State private var likedHashes: Set<String> = []
    @FocusState private var composerFocused: Bool

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
        .sheet(isPresented: $showingStickers) {
            StickerPickerSheet { url in
                Task { await sendSticker(url) }
            }
        }
    }

    private func load() async {
        loading = true
        failed = nil
        do {
            // Newest-first from the node, then each top-level cast's
            // conversation fetched in parallel and flattened in, so
            // replies show inline instead of hiding in threads. Capped
            // at 25 top-level casts to bound the fan-out.
            let top = try await FeedService.parentURL(room.parentURL, limit: 25, viewerFID: identity.record?.fid)
            var all = top
            await withTaskGroup(of: [Cast].self) { group in
                for cast in top {
                    group.addTask {
                        guard let thread = try? await FeedService.conversation(hash: cast.hash, viewerFID: identity.record?.fid) else {
                            return []
                        }
                        return Self.flatten(thread.directReplies ?? [])
                    }
                }
                for await replies in group {
                    all += replies
                }
            }
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
    /// text field and send. Sending while signed out opens the account
    /// sheet instead of failing.
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

            HStack(spacing: 10) {
                Button {
                    showingStickers = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.title2)
                        .foregroundStyle(Color.fwMuted)
                }
                .accessibilityLabel("Stickers")

                TextField("Message the room…", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.fwLine, lineWidth: 1))

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
            .background(Color.fwBackground)

            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(Color.fwAccentSoft)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
    }

    private func send() async {
        guard identity.isSignedIn else { showingProfile = true; return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        do {
            // Both branches wait for the new hash to appear in the
            // flattened list: a top-level post via parent_urls, a reply
            // via its parent's conversation.
            let hash: String
            if let replyingTo {
                hash = try await identity.reply(to: replyingTo, text: text)
                self.replyingTo = nil
            } else {
                hash = try await identity.post(text: text, parentURL: room.parentURL)
            }
            draft = ""
            composerFocused = false
            await reloadUntilVisible(hash: hash)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    /// Send a sticker: a cast with no text and the sticker image as
    /// its only embed. Same wait-for-it-to-land flow as send().
    private func sendSticker(_ url: String) async {
        guard identity.isSignedIn else { showingProfile = true; return }
        guard !sending else { return }
        sending = true
        sendError = nil
        do {
            let hash = try await identity.postSticker(url: url, parentURL: room.parentURL)
            await reloadUntilVisible(hash: hash)
        } catch {
            sendError = error.localizedDescription
        }
        sending = false
    }

    /// The node takes a moment to index a new cast into the parent_urls
    /// feed — the reload right after submit usually returns before it
    /// lands, so the message looks lost even though it posted fine
    /// (verified live 2026-11-20: the cast was in the feed minutes
    /// later, parent_url exact). Poll until the new hash shows up.
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let pfpURL = cast.author.pfpURL {
                AsyncImage(url: pfpURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.fwPanelSoft
                }
                .frame(width: 32, height: 32)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.fwMuted)
                    .frame(width: 32, height: 32)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // The username, not the display name: a display name
                    // can say anything, the username is who it is.
                    Text(cast.author.username ?? "fid:\(cast.author.fid.value)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwText)
                        .lineLimit(1)
                    Text(cast.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                }

                if let parent {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.fwAccent)
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("@\(parent.author.username ?? "fid:\(parent.author.fid.value)")")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.fwAccentSoft)
                            Text(parent.text)
                                .font(.caption)
                                .foregroundStyle(Color.fwMuted)
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 8))
                }

                CastTextView(cast: cast)
                    .font(.subheadline)
                    .foregroundStyle(Color.fwText)

                // Embeds: a sticker draws bare, a photo framed
                // (CastEmbedsView splits them). A sticker-only message
                // has no text, so this is the whole message.
                CastEmbedsView(cast: cast, onOpenQuote: nil)
            }
        }
        // Reply and like live on a long press, not on the row: the
        // row is just who said it, when, and what they said.
        .contextMenu {
            Button(action: onReply) {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button(action: onLike) {
                Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
            }
        }
    }
}
