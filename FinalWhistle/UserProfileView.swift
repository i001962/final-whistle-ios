import SwiftUI

/// A user's profile page, reached by tapping an @mention in a cast
/// (Quilcast's /u/<name>). Header from /v2/farcaster/user, recent casts
/// from /v2/farcaster/feed/user/casts (Quilcast app.tsx userCasts).
/// A cast in the list opens its thread; mentions inside those casts
/// push another profile, same as in the feed.
struct UserProfileView: View {
    let fid: FID
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var user: UserResponse.User?
    @State private var casts: [Cast] = []
    @State private var failed: String?
    @State private var replyingTo: Cast?
    @State private var quoting: Cast?
    @State private var selectedQuoted: Cast?
    @State private var notice: String?

    var body: some View {
        Group {
            if let user {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: user.pfpURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.fwPanelSoft
                            }
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(user.displayName ?? user.username ?? fid.fallbackUsername)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundStyle(Color.fwText)
                                Text("@\(user.username ?? fid.fallbackUsername)")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.fwMuted)
                                if let bio = user.bio, !bio.isEmpty {
                                    Text(bio)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.fwText)
                                }
                                HStack(spacing: 16) {
                                    if let followers = user.followerCount {
                                        Text("\(followers) followers")
                                            .font(.caption)
                                            .foregroundStyle(Color.fwMuted)
                                    }
                                    if let following = user.followingCount {
                                        Text("\(following) following")
                                            .font(.caption)
                                            .foregroundStyle(Color.fwMuted)
                                    }
                                }
                            }
                        }

                        if casts.isEmpty && failed == nil {
                            ProgressView()
                                .tint(Color.fwLime)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(casts) { cast in
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

                        if let notice {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(Color.fwMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .refreshable { await load() }
            } else if let failed {
                ContentUnavailableView(
                    "Profile did not load",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(failed)
                )
                .foregroundStyle(Color.fwMuted)
            } else {
                ProgressView("Loading profile…")
                    .tint(Color.fwLime)
                    .foregroundStyle(Color.fwMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.fwBackground)
        .navigationTitle(user?.username.map { "@\($0)" } ?? fid.fallbackUsername)
        .navigationBarTitleDisplayMode(.inline)
        // No system nav bar: without this it shows as a second header
        // under the app's own top bar. Back comes from that top bar
        // (upper left); swipe-back still works.
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(item: $replyingTo) { cast in
            ComposeView(parent: cast, onPosted: { Task { await load() } })
                .presentationDetents([.large])
        }
        .sheet(item: $quoting) { cast in
            ComposeView(quoted: cast, onPosted: {
                feed.markQuoted(cast)
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
            async let fetchedUser = FeedService.user(fid: fid)
            async let fetchedCasts = FeedService.userCasts(fid: fid)
            user = try await fetchedUser
            casts = try await fetchedCasts
            failed = nil
        } catch {
            if user == nil { failed = error.localizedDescription }
        }
    }
}
