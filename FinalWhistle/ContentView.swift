import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var identity: IdentityStore
    @EnvironmentObject private var feed: FeedStore
    @State private var browsingWithoutAccount = false
    @State private var showingProfile = false

    var body: some View {
        Group {
            if identity.isSignedIn || browsingWithoutAccount {
                NavigationStack {
                    FeedView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Text("Final Whistle")
                                    .font(.headline)
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button {
                                    showingProfile = true
                                } label: {
                                    Label("Account", systemImage: identity.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                                }
                                .accessibilityLabel(identity.isSignedIn ? "Account" : "Sign in")
                            }
                        }
                        .sheet(isPresented: $showingProfile) {
                            ProfileView()
                        }
                }
            } else {
                OnboardingView(browsingWithoutAccount: $browsingWithoutAccount)
            }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

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
                            dismiss()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
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
        }
    }
}
