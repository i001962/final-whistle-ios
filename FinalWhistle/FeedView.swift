import SwiftUI

/// The whole app is one list: the /football channel on Hypersnap.
/// No tabs, no trending. Styled on final-whistle.app: near-black navy
/// background, panel cards with a thin line border, lime highlights,
/// magenta for the compose button.
struct FeedView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var showingCompose = false
    @State private var replyingTo: Cast?
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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
                List(feed.casts) { cast in
                    CastRow(cast: cast, onReply: { replyingTo = cast }, onReacted: { notice = $0 })
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await feed.refresh() }
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
