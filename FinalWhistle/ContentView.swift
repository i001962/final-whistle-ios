import SwiftUI

/// The app opens straight onto the /football channel feed. No identity
/// is needed to read it. Signing in (bring a FID, or create a free
/// Hypersnap native FID) lives behind the Account button, and is only
/// needed to post, reply, like, or recast.
struct ContentView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            FeedView()
                .toolbar {
                    // Your profile picture is the account button, top
                    // left. The "Final Whistle" title text is gone: in a
                    // narrow window it truncated to "Fi..." and the
                    // channel header below already says where you are.
                    ToolbarItem(placement: .navigationBarLeading) {
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
                .sheet(isPresented: $showingProfile) {
                    ProfileView()
                }
        }
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
