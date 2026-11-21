import SwiftUI

/// Add-account screen, reached from Account. Two ways in: bring a FID you
/// already have, or create a free Hypersnap native FID. The account joins
/// the ones already on this phone and becomes the active one. The feed
/// itself needs no identity at all, so this screen never blocks opening
/// the app.
struct OnboardingView: View {
    @EnvironmentObject private var identity: IdentityStore
    @Environment(\.dismiss) private var dismiss

    @State private var fidText = ""
    @State private var seedText = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Add an account")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Add an account you already have, or create a new one. It joins the accounts already on this phone.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("I already have an account") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter your account ID and the sign-in key from when you set it up. The key stays on this phone only.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextField("Account ID, for example 4294967310", text: $fidText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44)
                            SecureField("Sign-in key, 64 characters", text: $seedText)
                                .textContentType(.none)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44)
                            Button("Sign in") {
                                Task { await bringYourFID() }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                            .disabled(working || fidText.isEmpty || seedText.isEmpty)
                        }
                    }

                    GroupBox("Create a new account") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Free. A new account is created on this phone, alongside your other accounts. Back up its recovery key from the Account panel afterwards, so you can get back in if you lose this phone.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if identity.isWorking {
                                ProgressView(identity.status.isEmpty ? "Working…" : identity.status)
                            }
                            Button("Create a free account") {
                                Task { await createNewFID() }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                            .disabled(identity.isWorking)
                        }
                    }

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button("Browse the feed without an account") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding()
            }
            .background(Color.fwBackground)
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
        }
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
            if identity.isSignedIn { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createNewFID() async {
        error = nil
        do {
            try await identity.createNewFID()
            if identity.isSignedIn { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
