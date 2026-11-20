import SwiftUI

/// A cast's thread, Quilcast-style (src/app.tsx Thread): the parents
/// above it (up to five, so a reply reads in context), the cast itself,
/// a reply prompt, then its replies as a real tree — every reply nested
/// under its parent, indented with a guide line, to any depth.
/// The old version showed only direct replies plus the first nested
/// reply, so a reply deep in a thread (e.g. "HBD" under Kazani's reply
/// to the birthday cast) rendered flat at the same level as its parent
/// and read as a standalone post. Replies come from the conversation
/// endpoint: the cast carries direct_replies, each reply carrying its own.
struct ThreadView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    let cast: Cast

    @State private var root: Cast?
    @State private var parents: [Cast] = []
    @State private var failed: String?
    @State private var replyingTo: Cast?
    @State private var quoting: Cast?
    @State private var selectedQuoted: Cast?
    @State private var notice: String?

    var body: some View {
        Group {
            if let root {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(parents) { parent in
                            NavigationLink(value: parent) {
                                CastRow(
                                    cast: parent,
                                    onReply: { replyingTo = parent },
                                    onQuote: { quoting = parent },
                                    onOpenQuote: { selectedQuoted = $0 },
                                    onReacted: { notice = $0 },
                                    inThread: true
                                )
                            }
                            .buttonStyle(.plain)
                            .opacity(0.85)
                        }

                        CastRow(
                            cast: root,
                            onReply: { replyingTo = root },
                            onQuote: { quoting = root },
                            onOpenQuote: { selectedQuoted = $0 },
                            onReacted: { notice = $0 },
                            inThread: true
                        )

                        if identity.isSignedIn {
                            Button {
                                replyingTo = root
                            } label: {
                                HStack {
                                    Text("Post your reply")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.fwMuted)
                                    Spacer()
                                }
                                .padding()
                                .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.fwLine, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        let replies = root.directReplies ?? []
                        if replies.isEmpty {
                            Text("No replies yet.")
                                .font(.subheadline)
                                .foregroundStyle(Color.fwMuted)
                                .padding(.top, 4)
                        }
                        ForEach(replies) { reply in
                            ThreadNodeView(
                                cast: reply,
                                onReply: { replyingTo = $0 },
                                onQuote: { quoting = $0 },
                                onOpenQuote: { selectedQuoted = $0 },
                                onReacted: { notice = $0 }
                            )
                        }

                        if let notice {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(Color.fwMuted)
                        }
                    }
                    .padding()
                }
            } else if let failed {
                ContentUnavailableView(
                    "Thread did not load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(failed)
                )
                .foregroundStyle(Color.fwMuted)
            } else {
                ProgressView("Loading thread…")
                    .tint(Color.fwLime)
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.fwBackground)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        // The system bar is hidden everywhere: ContentView's top bar
        // (back chevron + channel icon + pfp) is the navigation chrome,
        // and swipe-back still works.
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $replyingTo) { target in
            ComposeView(parent: target, onPosted: { Task { await load() } })
                .presentationDetents([.large])
        }
        .sheet(item: $quoting) { target in
            ComposeView(quoted: target, onPosted: {
                feed.markQuoted(target)
                Task { await load() }
            })
            .presentationDetents([.large])
        }
        .navigationDestination(for: Cast.self) { cast in
            ThreadView(cast: cast)
        }
        .navigationDestination(item: $selectedQuoted) { cast in
            ThreadView(cast: cast)
        }
    }

    private func load() async {
        do {
            // A cast just posted may take a moment to be indexed; retry
            // a few times before showing an error (Quilcast's Thread).
            var lastError: Error?
            for _ in 0..<5 {
                do {
                    let conversation = try await FeedService.conversation(
                        hash: cast.hash, viewerFID: identity.record?.fid
                    )
                    root = conversation
                    failed = nil
                    await loadParents(of: conversation)
                    return
                } catch {
                    lastError = error
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
            throw lastError ?? URLError(.badServerResponse)
        } catch {
            failed = error.localizedDescription
        }
    }

    private func loadParents(of conversation: Cast) async {
        var chain: [Cast] = []
        var nextHash = conversation.parentHash
        while let hash = nextHash, chain.count < 5 {
            do {
                let parent = try await FeedService.userCast(hash: hash)
                chain.insert(parent, at: 0)
                nextHash = parent.parentHash
            } catch {
                break
            }
        }
        parents = chain
    }
}

/// One node of the reply tree: the cast itself, then all of its children
/// recursively, each level indented 16pt with a vertical guide line, so
/// a reply reads as belonging to the cast above it. Tapping any cast
/// opens that cast's own thread (parents shown above it there).
struct ThreadNodeView: View {
    let cast: Cast
    let onReply: (Cast) -> Void
    let onQuote: (Cast) -> Void
    let onOpenQuote: (Cast) -> Void
    let onReacted: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: cast) {
                CastRow(
                    cast: cast,
                    onReply: { onReply(cast) },
                    onQuote: { onQuote(cast) },
                    onOpenQuote: onOpenQuote,
                    onReacted: onReacted,
                    inThread: true
                )
            }
            .buttonStyle(.plain)
            let children = cast.directReplies ?? []
            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(children) { child in
                        ThreadNodeView(
                            cast: child,
                            onReply: onReply,
                            onQuote: onQuote,
                            onOpenQuote: onOpenQuote,
                            onReacted: onReacted
                        )
                    }
                }
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Color.fwLine
                        .frame(width: 1)
                        .padding(.leading, 8)
                        .padding(.vertical, 6)
                }
            }
        }
    }
}
