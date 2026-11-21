import SwiftUI
import UIKit

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
/// Navigation follows the Footy app (footy.vercel.app): one top bar
/// for the whole app — back upper left whenever something is open
/// (thread, profile, room), the /football channel icon there at the
/// top level, and your profile picture always upper right — plus a
/// bottom tab bar — Feed, Videos, Rooms, Fantasy. Feed, Videos, and
/// Rooms are live; Fantasy is a menu first, feed next, so it shows a
/// placeholder for now. No favourite clubs/countries strip yet.
///
/// LESSON (2026-11-20): the top bar was first built as toolbar items
/// on the NavigationStack's Group — they silently never rendered (the
/// bar was empty in the simulator). Both bars here are plain views, so
/// they cannot vanish like that. The system navigation bar is hidden
/// and the top bar's back chevron (plus swipe-back) is the way out of
/// a thread.
enum AppTab: CaseIterable {
    case feed, videos, rooms, fantasy

    var label: String {
        switch self {
        case .feed: return "Feed"
        case .videos: return "Videos"
        case .rooms: return "Rooms"
        case .fantasy: return "Fantasy"
        }
    }

    var icon: String {
        switch self {
        case .feed: return "soccerball"
        case .videos: return "play.rectangle.on.rectangle"
        case .rooms: return "bubble.left.and.bubble.right"
        case .fantasy: return "star"
        }
    }
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
        VStack(spacing: 0) {
            topBar

            // One NavigationStack per tab, not one stack with a
            // switched root: switching the root inside a stack while
            // a destination is pushed leaves the pushed view on
            // screen with an empty path — no back chevron, and tabs
            // that highlight but change nothing. Each tab owns its
            // stack, so the stack and the path can never disagree.
            switch selectedTab {
            case .feed:
                tabStack { FeedView() }
            case .videos:
                tabStack { VideosView() }
            case .rooms:
                tabStack { RoomsView() }
            case .fantasy:
                tabStack {
                    ComingSoonView(
                        icon: "star",
                        title: "Fantasy",
                        text: "Your FPL mini leagues will live here, signed in with your Final Whistle account."
                    )
                }
            }

            tabBar
        }
        .background(Color.fwBackground)
        .sheet(isPresented: $showingProfile) {
            ProfileView()
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

    /// Back upper left whenever something is open (thread, profile,
    /// room), the /football channel icon there at the top level; your
    /// profile picture always upper right. One bar for the whole app.
    private var topBar: some View {
        HStack(spacing: 10) {
            if !router.path.isEmpty {
                Button {
                    router.path.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(Color.fwText)
                        .frame(width: 32, height: 32)
                        .background(Color.fwPanel, in: Circle())
                }
                .accessibilityLabel("Back")
            } else {
                AsyncImage(url: Self.channelImageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.fwPanelSoft
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Football channel")
            }

            Spacer()

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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// One tab's NavigationStack, bound to the shared router path.
    /// Profiles (from @mentions) can be pushed from any tab, so the
    /// FID destination lives here; threads register their own Cast
    /// destination inside FeedView/ThreadView.
    @ViewBuilder
    private func tabStack<Root: View>(@ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: $router.path) {
            root()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: FID.self) { fid in
                    UserProfileView(fid: fid)
                }
        }
    }

    /// Footy-style floating tab bar. Switching tabs pops any open
    /// thread first, so you always land on the section's top.
    ///
    /// Tapping a tab from inside a room also dismisses the composer's
    /// keyboard first — it sits over the footer, so the tap landed
    /// on the keyboard and nothing happened.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                    router.path = NavigationPath()
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.title3)
                        Text(tab.label)
                            .font(.caption2)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(selectedTab == tab ? .white : Color.fwMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selectedTab == tab ? Color.fwAccent : Color.clear,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .accessibilityLabel(tab.label)
            }
        }
        .padding(6)
        .background(Color.fwPanel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.fwLine, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// A section that has a menu entry but no feed yet.
// NOTE: the text property is called `text`, not `body` — a stored
// property named `body` would redeclare View's own `body` and the
// build fails with "Invalid redeclaration of 'body'".
private struct ComingSoonView: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: icon,
            description: Text(text)
        )
        .foregroundStyle(Color.fwMuted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.fwBackground)
    }
}

/// One row in the Accounts list: pfp, display name / FID, and a
/// checkmark for the active account (a spinner while it is switching).
/// A separate View so ProfileView.body stays small enough for the
/// compiler to type-check in reasonable time.
private struct AccountRowView: View {
    let account: IdentityRecord
    let isActive: Bool
    let isSwitching: Bool
    let isDisabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                if let pfpString = account.pfpURL, let pfpURL = URL(string: pfpString) {
                    AsyncImage(url: pfpURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.fwPanelSoft
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.fwMuted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.listTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.fwText)
                    Text("FID \(account.fid.description)")
                        .font(.caption)
                        .foregroundStyle(Color.fwMuted)
                }
                Spacer()
                if isSwitching {
                    ProgressView()
                } else if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.fwLime)
                }
            }
        }
        .disabled(isDisabled)
    }
}

struct ProfileView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var showingOnboarding = false
    // Switching accounts: which FID is being unlocked, and the last
    // switch error, shown as text only in the Accounts section.
    @State private var switchingFID: UInt64?
    @State private var switchError: String?
    // Authorizing Final Whistle: whether a renewal is running, and the
    // last authorize error, shown as text only in that section.
    @State private var authorizeBusy = false
    @State private var authorizeError: String?
    // Error text only — the panel says nothing while a save is
    // running or after it succeeds. A stale error clears when a new
    // attempt starts.
    @State private var photoStatus: String?
    @State private var pfpURLField = ""
    @State private var photoBusy = false
    @State private var displayNameField = ""
    @State private var displayNameError: String?
    @State private var displayNameBusy = false
    // Recovery: the key is only in state after the warning alert,
    // and only until hidden or the sheet is dismissed.
    @State private var showingRecoveryWarning = false
    @State private var recoveryKey: String?
    @State private var recoveryCopied = false
    @State private var recoveryError: String?

    var body: some View {
        NavigationStack {
            List {
                if identity.identities.isEmpty {
                    Section {
                        Text("You are browsing without an account. The feed works, but posting, replies, likes, and recasts need a Hypersnap FID.")
                        Button("Sign in or create a FID") {
                            showingOnboarding = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                } else {
                    // A title string and a footer cannot be combined
                    // in one Section call — there is no such overload,
                    // which is what the three ContentView errors were.
                    // The title goes in a header closure instead.
                    Section {
                        ForEach(identity.identities, id: \.fid) { account in
                            AccountRowView(
                                account: account,
                                isActive: account.fid == identity.record?.fid,
                                isSwitching: switchingFID == account.fid.value,
                                isDisabled: switchingFID != nil,
                                onSelect: { Task { await switchTo(account) } }
                            )
                        }
                        Button { showingOnboarding = true } label: {
                            Label("Add account", systemImage: "plus.circle")
                        }
                        if let switchError {
                            Text(switchError)
                                .font(.caption)
                                .foregroundStyle(Color.fwAccent)
                        }
                    } header: {
                        Text("Accounts")
                    } footer: {
                        Text("Tap an account to switch to it. Switching asks for Face ID or your passcode.")
                    }
                }
                if let record = identity.record {
                    Section("Profile photo") {
                        HStack(spacing: 12) {
                            if let pfpURL = identity.profile?.pfpURL {
                                AsyncImage(url: pfpURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.fwPanelSoft
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.system(size: 64))
                                    .foregroundStyle(Color.fwMuted)
                            }

                            TextField("Paste an image URL", text: $pfpURLField)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(photoBusy)
                        }

                        HStack {
                            Button("Use URL") { Task { await setPFPFromURL() } }
                                .disabled(photoBusy || pfpURLField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if photoBusy {
                                ProgressView()
                            }
                        }
                        if let photoStatus {
                            Text(photoStatus)
                                .font(.caption)
                                .foregroundStyle(Color.fwAccent)
                        }
                    }

                    Section("Display name") {
                        HStack {
                            TextField("Display name", text: $displayNameField)
                                .disabled(displayNameBusy)
                            Button("Save") { Task { await setDisplayNameFromField() } }
                                .disabled(displayNameBusy || displayNameField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if displayNameBusy {
                                ProgressView()
                            }
                        }
                        if let displayNameError {
                            Text(displayNameError)
                                .font(.caption)
                                .foregroundStyle(Color.fwAccent)
                        }
                    }
                    .onAppear {
                        // Prefill with the current name once; what the
                        // user typed is never overwritten.
                        if displayNameField.isEmpty {
                            displayNameField = identity.profile?.displayName ?? ""
                        }
                    }

                    Section("Hypersnap identity") {
                        LabeledContent("FID", value: record.fid.description)
                        LabeledContent("Username", value: identity.profile?.username ?? record.fid.fallbackUsername)
                        if let display = identity.profile?.displayName {
                            LabeledContent("Display name", value: display)
                        }
                        LabeledContent("Custody", value: record.custodyAddress)
                        LabeledContent("Signer", value: String(record.signerPublicKeyHex.prefix(16)) + "…")
                        Text("The signer is a rolling 30-day window: it renews every time you post, reply, or like, and only expires after 30 days without use.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("The custody key and signer seed are stored only in this phone's Keychain. They are never logged or uploaded — the key is only shown when you ask to back it up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    authorizationSection

                    // A title string and a footer cannot be combined
                    // in one Section call — there is no such overload,
                    // which is what the three build errors were. The
                    // title goes in a header closure instead.
                    Section {
                        Text("Your custody key is the only way back into this FID if you lose this phone. Signing out keeps it in this phone's Keychain, so you can always sign back in here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let recoveryKey {
                            Text(recoveryKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            HStack {
                                Button(recoveryCopied ? "Copied" : "Copy") { copyRecoveryKey() }
                                Spacer()
                                Button("Hide") {
                                    self.recoveryKey = nil
                                    recoveryCopied = false
                                }
                            }
                        } else {
                            Button("Show recovery key") { showingRecoveryWarning = true }
                        }
                        if let recoveryError {
                            Text(recoveryError)
                                .font(.caption)
                                .foregroundStyle(Color.fwAccent)
                        }
                    } header: {
                        Text("Recovery")
                    } footer: {
                        Text("There is no word phrase for this key — it was generated as raw bytes, so the private key itself is the backup. Anyone who has it can act as this account.")
                    }

                    Section {
                        Button("Sign out", role: .destructive) {
                            confirmingSignOut = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    } footer: {
                        Text("Signing out only deactivates this account. Its custody key and signer stay in this phone's Keychain, so tap the account above to sign back in.")
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
            .confirmationDialog("Sign out of this account?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    identity.signOut()
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("This key controls your FID", isPresented: $showingRecoveryWarning) {
                Button("Show key") { revealRecoveryKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The private key for FID \(identity.record?.fid.description ?? "this account") lets anyone post and act as this account, and add new signers. Never share it, never paste it into a website or chat, and store it somewhere only you can reach, like a password manager. If you lose it and lose this phone, the FID is gone for good.")
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView()
            }
            .task {
                // Check the active account's authorization on the node
                // when the panel opens, so the section shows the real
                // status instead of a stale local date.
                await identity.refreshAuthorization()
            }
        }
    }

    /// The Final Whistle authorization section, kept as its own computed
    /// property so ProfileView.body stays small enough for the compiler
    /// to type-check in reasonable time.
    private var authorizationSection: some View {
        Section("Final Whistle authorization") {
            if !identity.authorizationChecked {
                HStack {
                    Text("Checking authorization…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            } else {
                if identity.isAuthorized {
                    Text("Final Whistle can post, reply, like, and recast as this account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let expires = identity.authorizationExpiresAt {
                        LabeledContent("Expires if unused", value: expires.formatted(date: .abbreviated, time: .omitted))
                    }
                } else {
                    Text("Final Whistle is not authorized to post as this account. Authorizing makes a fresh signer for the app, good for a 30-day window that renews every time you post.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    // Two separate Buttons with literal titles: a ternary
                    // in the title makes the Button overload ambiguous
                    // (String vs LocalizedStringKey) and the compiler
                    // cannot pick one.
                    if identity.isAuthorized {
                        Button("Re-authorize") { Task { await authorizeApp() } }
                            .disabled(authorizeBusy)
                    } else {
                        Button("Authorize Final Whistle") { Task { await authorizeApp() } }
                            .disabled(authorizeBusy)
                    }
                    if authorizeBusy {
                        ProgressView()
                    }
                }
                if let authorizeError {
                    Text(authorizeError)
                        .font(.caption)
                        .foregroundStyle(Color.fwAccent)
                }
            }
            if let authError = identity.authorizationError {
                Text("Could not check the authorization: \(authError)")
                    .font(.caption)
                    .foregroundStyle(Color.fwAccent)
            }
        }
    }

    /// Authorize (or re-authorize) Final Whistle for the active account.
    /// This is the KeyAdd renewal, framed as authorizing the app: it
    /// makes a fresh signer, so the app can keep posting as the account.
    /// The error is shown as text only in the authorization section.
    private func authorizeApp() async {
        guard !authorizeBusy else { return }
        authorizeBusy = true
        authorizeError = nil
        defer { authorizeBusy = false }
        do {
            try await identity.authorizeApp()
        } catch {
            authorizeError = error.localizedDescription
        }
    }

    /// Switch to an account from the list. Face ID / passcode gates the
    /// switch (see IdentityStore.switchTo). The sheet stays open so the
    /// user can pick another account; the feed reloads for the new FID
    /// on its own.
    private func switchTo(_ account: IdentityRecord) async {
        guard switchingFID == nil else { return }
        guard account.fid != identity.record?.fid else { return }
        switchingFID = account.fid.value
        switchError = nil
        defer { switchingFID = nil }
        do {
            try await identity.switchTo(fid: account.fid.value)
        } catch {
            switchError = error.localizedDescription
        }
    }

    /// Reveal the custody private key after the warning alert. The key
    /// is never logged; it only lives in this view's state until hidden
    /// or the sheet is dismissed. A brought-your-own FID has no custody
    /// key on this phone (signer only), so there is nothing to show.
    private func revealRecoveryKey() {
        recoveryError = nil
        recoveryCopied = false
        do {
            recoveryKey = try identity.custodyPrivateKeyHex()
        } catch KeychainStore.KeychainError.notFound {
            recoveryError = "No custody key is stored on this phone — this FID was signed in with a signer only, so there is nothing to back up here."
        } catch {
            recoveryError = "Could not load the recovery key: \(error.localizedDescription)"
        }
    }

    private func copyRecoveryKey() {
        guard let recoveryKey else { return }
        UIPasteboard.general.string = recoveryKey
        recoveryCopied = true
    }

    /// Save the display name: UserDataAdd type 2. Farcaster caps
    /// display names at 32 characters.
    private func setDisplayNameFromField() async {
        let name = displayNameField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            displayNameError = "Enter a display name first."
            return
        }
        guard name.count <= 32 else {
            displayNameError = "Display names are at most 32 characters."
            return
        }
        displayNameBusy = true
        displayNameError = nil
        defer { displayNameBusy = false }
        do {
            _ = try await identity.setDisplayName(name)
        } catch {
            displayNameError = "Could not set the display name: \(error.localizedDescription)"
        }
    }

    /// A pfp the user already has hosted somewhere: its URL goes
    /// straight into the UserDataAdd, no upload.
    private func setPFPFromURL() async {
        let url = pfpURLField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("https://") else {
            photoStatus = "That needs to be a full https:// image link."
            return
        }
        photoBusy = true
        photoStatus = nil
        defer { photoBusy = false }
        do {
            _ = try await identity.setPFP(url: url)
            pfpURLField = ""
        } catch {
            photoStatus = "Could not set the photo: \(error.localizedDescription)"
        }
    }

}
