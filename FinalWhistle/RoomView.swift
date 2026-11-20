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
    let subtitle: String
    let parentURL: String

    static let all: [ChatRoom] = [
        ChatRoom(
            id: "1",
            title: "The Gantry",
            subtitle: "Live match chat — final-whistle.app/chat/1",
            parentURL: "https://final-whistle.app/chat/1"
        ),
    ]
}

/// The rooms directory: one row per room.
struct RoomsView: View {
    var body: some View {
        List {
            Section {
                ForEach(ChatRoom.all) { room in
                    NavigationLink {
                        RoomView(room: room)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.title3)
                                .foregroundStyle(Color.fwAccent)
                                .frame(width: 40, height: 40)
                                .background(Color.fwPanelSoft, in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.title)
                                    .font(.headline)
                                    .foregroundStyle(Color.fwText)
                                Text(room.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.fwMuted)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } footer: {
                Text("Live match rooms — group chat for the match, with threaded replies and reactions. One room per match; more rooms coming.")
                    .foregroundStyle(Color.fwMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
    }
}

// MARK: - One room: IRC-style chat

/// A room as a group chat: messages oldest-first, a composer at the
/// bottom, tap a message to reply in its thread, heart to like.
/// A top-level message posts with the room as parent_url; a reply
/// posts with parent_cast_id, so it lives in the message's thread
/// (opened from the "N replies" link) rather than in the room list.
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
    @State private var likedHashes: Set<String> = []
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if loading, messages.isEmpty {
                            ProgressView("Loading room…")
                                .tint(Color.fwLime)
                                .foregroundStyle(Color.fwMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        } else if let failed, messages.isEmpty {
                            ContentUnavailableView(
                                "Room did not load",
                                systemImage: "wifi.exclamationmark",
                                description: Text(failed)
                            )
                            .foregroundStyle(Color.fwMuted)
                        } else if messages.isEmpty {
                            ContentUnavailableView(
                                "No messages yet",
                                systemImage: "bubble.left.and.bubble.right",
                                description: Text("Be the first to say something about the match.")
                            )
                            .foregroundStyle(Color.fwMuted)
                        } else {
                            ForEach(messages) { cast in
                                RoomMessageRow(
                                    cast: cast,
                                    liked: isLiked(cast),
                                    likesCount: likesCount(for: cast),
                                    onLike: { Task { await toggleLike(cast) } },
                                    onReply: {
                                        replyingTo = cast
                                        composerFocused = true
                                    }
                                )
                                .id(cast.hash)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .refreshable { await load() }
                .onChange(of: messages.count) {
                    scrollToBottom(proxy)
                }
            }

            composer
        }
        .background(Color.fwBackground)
        .navigationDestination(for: Cast.self) { cast in
            ThreadView(cast: cast)
        }
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        withAnimation {
            proxy.scrollTo(last.hash, anchor: .bottom)
        }
    }

    private func load() async {
        loading = true
        failed = nil
        do {
            // Newest-first from the node, flipped to chat order.
            let casts = try await FeedService.parentURL(room.parentURL, viewerFID: identity.record?.fid)
            messages = casts.reversed()
            likedHashes = Set(casts.filter { $0.viewerContext?.liked == true }.map { $0.hash.lowercased() })
        } catch {
            failed = error.localizedDescription
        }
        loading = false
    }

    private func isLiked(_ cast: Cast) -> Bool { likedHashes.contains(cast.hash.lowercased()) }

    /// Server count, adjusted for a tap the server has not caught up
    /// with yet — the same adjustment FeedStore makes for the feed.
    private func likesCount(for cast: Cast) -> Int {
        let base = cast.reactions.likesCount
        let serverSaysLiked = cast.viewerContext?.liked ?? false
        if isLiked(cast) && !serverSaysLiked { return base + 1 }
        if !isLiked(cast) && serverSaysLiked { return max(0, base - 1) }
        return base
    }

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
            if let replyingTo {
                _ = try await identity.reply(to: replyingTo, text: text)
                draft = ""
                self.replyingTo = nil
                composerFocused = false
                // A reply lives in the message's thread, not the room
                // list — one delayed reload refreshes its reply count.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await load()
            } else {
                let hash = try await identity.post(text: text, parentURL: room.parentURL)
                draft = ""
                composerFocused = false
                await reloadUntilVisible(hash: hash)
            }
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

/// One message in the room: pfp, name, time, text with mentions put
/// back, then like and reply. Replies live in the message's thread.
private struct RoomMessageRow: View {
    let cast: Cast
    let liked: Bool
    let likesCount: Int
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
                    Text(cast.author.displayName ?? cast.author.username ?? "fid:\(cast.author.fid.value)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwText)
                        .lineLimit(1)
                    Text(cast.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                }

                CastTextView(cast: cast)
                    .font(.subheadline)
                    .foregroundStyle(Color.fwText)

                HStack(spacing: 16) {
                    Button(action: onLike) {
                        HStack(spacing: 4) {
                            Image(systemName: liked ? "heart.fill" : "heart")
                            if likesCount > 0 { Text("\(likesCount)") }
                        }
                        .font(.caption)
                        .foregroundStyle(liked ? Color.fwAccent : Color.fwMuted)
                    }
                    .accessibilityLabel(liked ? "Unlike" : "Like")

                    Button(action: onReply) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.left")
                            Text("Reply")
                        }
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                    }
                    .accessibilityLabel("Reply to this message")

                    if cast.replies.count > 0 {
                        NavigationLink(value: cast) {
                            Text("\(cast.replies.count) \(cast.replies.count == 1 ? "reply" : "replies") ›")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.fwAccentSoft)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
