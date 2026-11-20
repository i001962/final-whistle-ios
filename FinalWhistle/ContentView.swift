import SwiftUI

/// Programmatic navigation for taps that can't use a NavigationLink:
/// an @mention inside a cast's text is an AttributedString link, not a
/// button, so it navigates by appending to this path. The link is the
/// in-app `fw://mention/<fid>` URL, intercepted by the openURL
/// environment on the stack below.
@MainActor
final class Router: ObservableObject {
    @Published var path = NavigationPath()

    func openProfile(_ fid: FID) {
        path.append(fid)
    }
}

/// The app opens straight onto the /football channel feed. No identity
/// is needed to read it. Signing in (bring a FID, or create a free
/// Hypersnap native FID) lives behind the Account button, and is only
/// needed to post, reply, like, or recast.
///
/// The top bar is the app's icon navigation: the /football channel icon
/// next to your profile picture on the left, and a feed/videos pill in
/// the middle. There is no "Football channel" text header any more.
enum AppTab {
    case feed, videos
}

struct ContentView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @EnvironmentObject private var router: Router
    @State private var showingProfile = false
    @State private var selectedTab = AppTab.feed

    // /football channel image, from the channel list at
    // hypersnap-stats.qstorage.quilibrium.com/all-channels-formatted.json
    // (id "football", 25,587 followers, 1,143 members, public casting).
    private static let channelImageURL = URL(string: "https://imagedelivery.net/BXluQx4ige9GuW0Ia56BHw/e457005e-e084-4e2e-288b-d94160184700/original")!

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                switch selectedTab {
                case .feed:
                    FeedView()
                case .videos:
                    VideosView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 10) {
                        AsyncImage(url: Self.channelImageURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.fwPanelSoft
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Football channel")

                        Button {
                            showingProfile = true
                        } label: {
                            if let pfpURL = identity.profile?.pfpURL {
                                AsyncImage(url: pfpURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.fwPanelSoft
                                }
                                .frame(width: 32, height: 32)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: identity.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                                    .font(.title2)
                                    .foregroundStyle(Color.fwAccent)
                            }
                        }
                        .accessibilityLabel(identity.isSignedIn ? "Account" : "Sign in")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        tabButton(.feed, icon: "soccerball", label: "Feed")
                        tabButton(.videos, icon: "play.rectangle.on.rectangle", label: "Videos")
                    }
                    .padding(3)
                    .background(Color.fwPanel, in: Capsule())
                    .overlay(Capsule().stroke(Color.fwLine, lineWidth: 1))
                }
            }
            .sheet(isPresented: $showingProfile) {
                ProfileView()
            }
            .navigationDestination(for: FID.self) { fid in
                UserProfileView(fid: fid)
            }
        }
        // Mention links (fw://mention/<fid>) push that user's profile;
        // every other link (bare URLs in cast text, video tiles, link
        // cards) opens as usual.
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "fw", url.host == "mention",
               let raw = url.pathComponents.last, let value = UInt64(raw) {
                Task { @MainActor in router.openProfile(FID(value)) }
                return .handled
            }
            return .systemAction
        })
    }

    private func tabButton(_ tab: AppTab, icon: String, label: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.headline)
                .foregroundStyle(selectedTab == tab ? .white : Color.fwMuted)
                .frame(width: 44, height: 32)
                .background(selectedTab == tab ? Color.fwAccent : Color.clear, in: Capsule())
        }
        .accessibilityLabel(label)
    }
}

struct ProfileView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var showingOnboarding = false

    var body: some View {
        NavigationStack {
            List {
                if let record = identity.record {
                    Section("Hypersnap identity") {
                        LabeledContent("FID", value: record.fid.description)
                        LabeledContent("Username", value: identity.profile?.username ?? record.fid.fallbackUsername)
                        if let display = identity.profile?.displayName {
                            LabeledContent("Display name", value: display)
                        }
                        LabeledContent("Custody", value: record.custodyAddress)
                        LabeledContent("Signer", value: String(record.signerPublicKeyHex.prefix(16)) + "…")
                        if let expires = record.signerExpiresAt {
                            LabeledContent("Signer expires", value: expires.formatted(date: .abbreviated, time: .omitted))
                        }
                        Text("The custody key and signer seed are stored only in this phone's Keychain. They are never shown, logged, or uploaded.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("Sign out", role: .destructive) {
                            confirmingSignOut = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    } footer: {
                        Text("Signing out wipes the custody key and signer seed from the Keychain. Without a saved copy of the custody key, that FID cannot be recovered.")
                    }
                } else {
                    Section {
                        Text("You are browsing without an account. The feed works, but posting, replies, likes, and recasts need a Hypersnap FID.")
                        Button("Sign in or create a FID") {
                            showingOnboarding = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.fwBackground)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Sign out and wipe the keys from this phone?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out and wipe keys", role: .destructive) {
                    identity.signOut()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView()
            }
        }
    }
}
