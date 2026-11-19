import SwiftUI

struct FeedView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var showingCompose = false
    @State private var replyingTo: Cast?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Feed", selection: $feed.tab) {
                ForEach(FeedTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .onChange(of: feed.tab) {
                Task { await feed.refresh() }
            }

            switch feed.state {
            case .loading where feed.casts.isEmpty:
                ProgressView("Loading the feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No casts yet",
                    systemImage: "sportscourt",
                    description: Text("Nothing in this feed right now. Pull to refresh.")
                )
            case .failed(let message):
                ContentUnavailableView(
                    "The feed did not load",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
            default:
                List(feed.casts) { cast in
                    CastRow(cast: cast, onReply: { replyingTo = cast }, onReacted: { notice = $0 })
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                .listStyle(.plain)
                .refreshable { await feed.refresh() }
            }

            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if identity.isSignedIn {
                Button {
                    showingCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
                .accessibilityLabel("New post")
                .padding()
            }
        }
        .sheet(isPresented: $showingCompose) {
            ComposeView(parent: nil)
        }
        .sheet(item: $replyingTo) { cast in
            ComposeView(parent: cast)
        }
        .task { await feed.refresh() }
    }
}

struct CastRow: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    let cast: Cast
    let onReply: () -> Void
    let onReacted: (String) -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                AsyncImage(url: cast.author.pfpURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.3)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(cast.author.displayTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("@\(cast.author.displayUsername)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(cast.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(cast.text)
                .font(.body)

            HStack(spacing: 24) {
                Button(action: onReply) {
                    Label("\(cast.replies.count)", systemImage: "bubble.left")
                }
                .disabled(!identity.isSignedIn)
                Button {
                    Task { await react(type: 2, label: "Recast") }
                } label: {
                    Label("\(cast.reactions.recastsCount)", systemImage: "repeat")
                }
                .disabled(!identity.isSignedIn || working)
                Button {
                    Task { await react(type: 1, label: "Like") }
                } label: {
                    Label("\(cast.reactions.likesCount)", systemImage: "heart")
                }
                .disabled(!identity.isSignedIn || working)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .frame(minHeight: 44)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func react(type: UInt64, label: String) async {
        working = true
        defer { working = false }
        do {
            let hash = try await identity.react(to: cast, type: type)
            feed.bumpReaction(for: cast.hash, like: type == 1)
            onReacted("\(label) posted: \(hash)")
        } catch {
            onReacted("\(label) failed: \(error.localizedDescription)")
        }
    }
}
