import SwiftUI

/// Sign-in screen, reached from Account. Two ways in: bring a FID you
/// already have, or create a free Hypersnap native FID. The feed itself
/// needs no identity at all, so this screen never blocks opening the app.
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
                        Text("Final Whistle")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Football talk on Hypersnap. Bring a FID you already have, or create a free Hypersnap native FID here.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Bring your FID") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter your FID and the Ed25519 signer seed from your earlier onboarding. The seed is stored only in this phone's Keychain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            TextField("FID, for example 4294967310", text: $fidText)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44)
                            SecureField("Signer seed, 64 hex characters", text: $seedText)
                                .textContentType(.none)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                                .frame(minHeight: 44)
                            Button("Sign in with this FID") {
                                Task { await bringYourFID() }
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                            .disabled(working || fidText.isEmpty || seedText.isEmpty)
                        }
                    }

                    GroupBox("Create a new Hypersnap FID") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Free, Hypersnap only, no ETH, no rented storage. A fresh custody key and signer are generated on this phone. One custody address gets one FID, and custody cannot be changed later, so losing the custody key loses the FID. Native FIDs do not appear on Warpcast.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if identity.isWorking {
                                ProgressView(identity.status.isEmpty ? "Working…" : identity.status)
                            }
                            Button("Create a free Hypersnap FID") {
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
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func bringYourFID() async {
        working = true
        error = nil
        defer { working = false }
        guard let fid = UInt64(fidText.trimmingCharacters(in: .whitespaces)) else {
            error = "Enter a numeric FID."
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
