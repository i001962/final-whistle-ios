import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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

            NavigationStack(path: $router.path) {
                Group {
                    switch selectedTab {
                    case .feed:
                        FeedView()
                            .toolbar(.hidden, for: .navigationBar)
                    case .videos:
                        VideosView()
                            .toolbar(.hidden, for: .navigationBar)
                    case .rooms:
                        RoomsView()
                            .toolbar(.hidden, for: .navigationBar)
                    case .fantasy:
                        ComingSoonView(
                            icon: "star",
                            title: "Fantasy",
                            text: "Your FPL mini leagues will live here, signed in with your Final Whistle account."
                        )
                        .toolbar(.hidden, for: .navigationBar)
                    }
                }
                .navigationDestination(for: FID.self) { fid in
                    UserProfileView(fid: fid)
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

    /// Footy-style floating tab bar. Switching tabs pops any open
    /// thread first, so you always land on the section's top.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
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

struct ProfileView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var showingOnboarding = false
    @State private var showingPhotoPicker = false
    @State private var pickedPreview: UIImage?
    // Error text only — the panel says nothing while an upload is
    // running or after it succeeds. A stale error clears when a new
    // attempt starts.
    @State private var photoStatus: String?
    @State private var pfpURLField = ""
    @State private var photoBusy = false

    var body: some View {
        NavigationStack {
            List {
                if let record = identity.record {
                    Section("Profile photo") {
                        HStack(spacing: 12) {
                            if let preview = pickedPreview {
                                Image(uiImage: preview)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                            } else if let pfpURL = identity.profile?.pfpURL {
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

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Button("Change photo") { showingPhotoPicker = true }
                                        .disabled(photoBusy)
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
                        }

                        HStack {
                            TextField("Or paste an image URL", text: $pfpURLField)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(photoBusy)
                            Button("Use URL") { Task { await setPFPFromURL() } }
                                .disabled(photoBusy || pfpURLField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .sheet(isPresented: $showingPhotoPicker) {
                // The plain `.photosPicker` sheet shows no Cancel on
                // this phone, so there was no way out without picking.
                // This one is our own sheet with a Cancel button.
                NavigationStack {
                    PhotoLibraryPicker(
                        onPick: { data in
                            showingPhotoPicker = false
                            Task { await setPFPFromPicker(data) }
                        },
                        onCancel: { showingPhotoPicker = false }
                    )
                    .navigationTitle("Choose a photo")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingPhotoPicker = false }
                        }
                    }
                }
            }
        }
    }

    /// Picked photo → square JPEG → Castrater pfp upload (signed by
    /// the FID's signer, one per FID, no payment) → UserDataAdd (pfp).
    /// The picked image shows in the panel immediately.
    private func setPFPFromPicker(_ data: Data) async {
        photoBusy = true
        photoStatus = nil
        defer { photoBusy = false }
        do {
            guard let image = UIImage(data: data),
                  let jpeg = ProfilePhotoService.preparedJPEG(from: image) else {
                throw PhotoError.badImage
            }
            pickedPreview = image
            let url = try await identity.uploadPFP(jpeg: jpeg)
            _ = try await identity.setPFP(url: url)
            pfpURLField = ""
        } catch {
            photoStatus = "Could not set the photo: \(error.localizedDescription)"
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

    private enum PhotoError: Error, LocalizedError {
        case badImage

        var errorDescription: String? {
            switch self {
            case .badImage: return "That photo could not be read."
            }
        }
    }
}

/// The system photo picker (PHPickerViewController) wrapped so the
/// sheet it lives in has a Cancel button we own. The plain
/// `.photosPicker` modifier shows no Cancel on this phone's picker
/// UI, so there was no way out without picking a photo. Dismissing
/// with nothing picked calls onCancel; picking calls onPick with the
/// image bytes.
private struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPick: (Data) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let item = results.first else {
                parent.onCancel()
                return
            }
            item.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                DispatchQueue.main.async {
                    if let data {
                        self.parent.onPick(data)
                    } else {
                        self.parent.onCancel()
                    }
                }
            }
        }
    }
}
