import SwiftUI

/// Add-account screen, reached from Account. A hub, like the Account
/// panel: one row per way in, each opening a focused screen, instead of
/// all three forms stacked at once. Three ways in: sign in with an
/// account you already have (account ID + sign-in key), sign in with
/// your recovery key (account ID + custody private key — a fresh sign-in
/// key is made for this phone), or create a free new account on this
/// phone. The account joins the ones already on this phone and becomes
/// the active one. The feed itself needs no identity at all, so this
/// screen never blocks opening the app.
struct OnboardingView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SignInView(onSignedIn: { dismiss() })
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("I already have an account")
                                Text("Sign in with your sign-in key")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.badge.key")
                        }
                    }
                    NavigationLink {
                        RecoverySignInView(onSignedIn: { dismiss() })
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sign in with your recovery key")
                                Text("Use the private key you backed up")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "key")
                        }
                    }
                    NavigationLink {
                        CreateAccountView(onSignedIn: { dismiss() })
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Create a new account")
                                Text("Free, made on this phone")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "plus.circle")
                        }
                    }
                } header: {
                    Text("Add an account you already have, or create a new one. It joins the accounts already on this phone.")
                }

                Section {
                    Button("Browse the feed without an account") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.fwBackground)
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The header needs a way out: without this, the only
                // dismiss paths are the button at the bottom of the
                // list or a swipe-down, and the header has no
                // tappable affordance at all.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Sign in with an account ID + the sign-in key (signer seed) from when
/// the account was set up on another device. The sign-in key is NOT the
/// recovery key: a custody private key entered here fails with the
/// node's "signer not active" error, because a custody key is not a
/// signer. The recovery-key screen is the path for that key.
private struct SignInView: View {
    @EnvironmentObject private var identity: IdentityStore
    let onSignedIn: () -> Void
    @State private var fidText = ""
    @State private var seedText = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField("Account ID (your FID number), for example 4294967310", text: $fidText)
                    .keyboardType(.numberPad)
                SecureField("Sign-in key, 64 characters", text: $seedText)
                    .textContentType(.none)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Sign in with your sign-in key")
            } footer: {
                Text("This is the 64-character sign-in key from when you set this account up on another device, not your recovery key.")
            }

            Section {
                Button("Sign in") {
                    Task { await bringYourFID() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(working || fidText.isEmpty || seedText.isEmpty)
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
        .navigationTitle("I already have an account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bringYourFID() async {
        working = true
        error = nil
        defer { working = false }
        guard let fid = UInt64(fidText.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter a numeric account ID."
            return
        }
        do {
            try await identity.bringYourFID(fid: fid, signerSeedHex: seedText.trimmingCharacters(in: .whitespaces))
            if identity.isSignedIn { onSignedIn() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Sign in with an account ID + the recovery key (custody private key)
/// the user backed up. The app checks the key belongs to the account,
/// then makes a fresh sign-in key for this phone.
private struct RecoverySignInView: View {
    @EnvironmentObject private var identity: IdentityStore
    let onSignedIn: () -> Void
    @State private var fidText = ""
    @State private var keyText = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField("Account ID (your FID number), for example 4294967310", text: $fidText)
                    .keyboardType(.numberPad)
                SecureField("Recovery key, 64 characters", text: $keyText)
                    .textContentType(.none)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } header: {
                Text("Sign in with your recovery key")
            } footer: {
                Text("If you only have your recovery key — the private key you backed up from the Account panel — enter it here. Final Whistle checks it belongs to this account, then makes a fresh sign-in key for this phone.")
            }

            Section {
                Button("Sign in with recovery key") {
                    Task { await bringYourFIDWithCustody() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(working || fidText.isEmpty || keyText.isEmpty)
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
        .navigationTitle("Sign in with your recovery key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bringYourFIDWithCustody() async {
        working = true
        error = nil
        defer { working = false }
        guard let fid = UInt64(fidText.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter a numeric account ID."
            return
        }
        do {
            try await identity.bringYourFIDWithCustody(fid: fid, custodyPrivateKeyHex: keyText.trimmingCharacters(in: .whitespaces))
            if identity.isSignedIn { onSignedIn() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Create a free new account on this phone.
private struct CreateAccountView: View {
    @EnvironmentObject private var identity: IdentityStore
    let onSignedIn: () -> Void
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Free. A new account is created on this phone, alongside your other accounts. Back up its recovery key from the Account panel afterwards, so you can get back in if you lose this phone.")
            } header: {
                Text("Create a new account")
            }

            Section {
                if identity.isWorking {
                    ProgressView(identity.status.isEmpty ? "Working…" : identity.status)
                }
                Button("Create a free account") {
                    Task { await createNewFID() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(identity.isWorking)
            }

            if let error {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.fwBackground)
        .navigationTitle("Create a new account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func createNewFID() async {
        error = nil
        do {
            try await identity.createNewFID()
            if identity.isSignedIn { onSignedIn() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
