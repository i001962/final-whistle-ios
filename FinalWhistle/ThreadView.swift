import SwiftUI

/// A cast's thread, Quilcast-style (src/app.tsx Thread): the parents
/// above it (up to five, so a reply reads in context), the cast itself,
/// a reply prompt, then its direct replies, each with its first nested
/// reply and a "show more" link into that reply's own thread.
/// Replies come from the conversation endpoint: the cast carries
/// direct_replies, each reply carrying its own.
struct ThreadView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    let cast: Cast

    @State private var root: Cast?
    @State private var parents: [Cast] = []
    @State private var failed: String?
    @State private var replyingTo: Cast?
    @State private var quoting: Cast?
    @State private var childThread: Cast?
    @State private var notice: String?

    var body: some View {
        Group {
            if let root {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(parents) { parent in
                            CastRow(
                                cast: parent,
                                onReply: { replyingTo = parent },
                                onQuote: { quoting = parent },
                                onThread: { childThread = parent },
                                onReacted: { notice = $0 }
                            )
                            .opacity(0.85)
                        }

                        CastRow(
                            cast: root,
                            onReply: { replyingTo = root },
                            onQuote: { quoting = root },
                            onThread: {},
                            onReacted: { notice = $0 }
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
                            VStack(alignment: .leading, spacing: 8) {
                                CastRow(
                                    cast: reply,
                                    onReply: { replyingTo = reply },
                                    onQuote: { quoting = reply },
                                    onThread: { childThread = reply },
                                    onReacted: { notice = $0 }
                                )
                                let kids = reply.directReplies ?? []
                                if let first = kids.first {
                                    CastRow(
                                        cast: first,
                                        onReply: { replyingTo = first },
                                        onQuote: { quoting = first },
                                        onThread: { childThread = first },
                                        onReacted: { notice = $0 }
                                    )
                                    .padding(.leading, 24)
                                }
                                if kids.count > 1 {
                                    Button("\(kids.count - 1) more \(kids.count - 1 == 1 ? "reply" : "replies")") {
                                        childThread = reply
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(Color.fwAccentSoft)
                                    .padding(.leading, 24)
                                }
                            }
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
        .task { await load() }
        .sheet(item: $replyingTo) { target in
            ComposeView(parent: target, onPosted: { Task { await load() } })
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $quoting) { target in
            ComposeView(quoted: target, onPosted: {
                feed.markQuoted(target)
                Task { await load() }
            })
            .presentationDetents([.medium, .large])
        }
        .navigationDestination(item: $childThread) { cast in
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
